<%@ WebHandler Language="C#" Class="DeliverooWebhook" %>

using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Web;
using System.Configuration;
using System.Security.Cryptography;
using System.Net;
using System.Threading;
using System.Web.Script.Serialization;
using System.Diagnostics;
using System.Collections.Concurrent;
using System.Collections;
using MySql.Data.MySqlClient;

public class DeliverooWebhook : IHttpHandler
{
    // Un lock per external_order_id, non uno globale: cosi' il retry lento
    // di un ordine non blocca il salvataggio di tutti gli altri ordini in coda.
    private static readonly ConcurrentDictionary<string, object> OrderLocks = new ConcurrentDictionary<string, object>();

    // Timeout brevi e volutamente aggressivi: un tentativo che si blocca deve
    // fallire in fretta, cosi' il retry (e chi aspetta lo stesso lock per-ordine)
    // non resta appeso per il default del driver (~30s per tentativo).
    private const int ConnectionTimeoutSeconds = 5;
    private const int CommandTimeoutSeconds = 5;

    private object GetOrderLock(string orderId)
    {
        return OrderLocks.GetOrAdd(orderId, delegate { return new object(); });
    }

    public bool IsReusable { get { return false; } }

    // Funzione comune per aprire una connessione al database MySQL.
    // Centralizza la lettura della connection string e l'apertura,
    // cosi' i vari metodi non duplicano piu' questa logica.
    private MySqlConnection GetOpenConnection()
    {
        var builder = new MySqlConnectionStringBuilder(
            ConfigurationManager.ConnectionStrings["MySqlConnectionString"].ConnectionString);
        builder.ConnectionTimeout = (uint)ConnectionTimeoutSeconds;
        var connection = new MySqlConnection(builder.ConnectionString);
        connection.Open();
        return connection;
    }

    // Funzione comune per estrarre l'oggetto "order" da un payload webhook Deliveroo.
    private Dictionary<string, object> ExtractOrder(string body, out Dictionary<string, object> envelope)
    {
        envelope = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(body);
        var eventBody = envelope["body"] as Dictionary<string, object>;
        return eventBody == null ? null : eventBody["order"] as Dictionary<string, object>;
    }

    public void ProcessRequest(HttpContext context)
    {
        if (string.Equals(context.Request.HttpMethod, "GET", StringComparison.OrdinalIgnoreCase) &&
            string.Equals(context.Request.QueryString["diagnostics"], "1", StringComparison.Ordinal) &&
            IsDiagnosticsKeyValid(context.Request.QueryString["key"]))
        {
            WriteDiagnostics(context);
            return;
        }

        if (!string.Equals(context.Request.HttpMethod, "POST", StringComparison.OrdinalIgnoreCase))
        {
            context.Response.StatusCode = 405;
            context.Response.ContentType = "application/json";
            context.Response.Write("{\"error\":\"POST required\"}");
            return;
        }

        byte[] rawBody;
        using (var buffer = new MemoryStream())
        {
            context.Request.InputStream.CopyTo(buffer);
            rawBody = buffer.ToArray();
        }
        var body = Encoding.UTF8.GetString(rawBody);

        var webhookSecret = ConfigurationManager.AppSettings["DeliverooWebhookSecret"];
        var sequenceGuid = context.Request.Headers["X-Deliveroo-Sequence-Guid"];
        var suppliedHmac = context.Request.Headers["X-Deliveroo-Hmac-Sha256"];
        if (!string.IsNullOrEmpty(webhookSecret))
        {
            if (string.IsNullOrEmpty(sequenceGuid) || string.IsNullOrEmpty(suppliedHmac))
            {
                context.Response.StatusCode = 401;
                context.Response.ContentType = "application/json";
                context.Response.Write("{\"error\":\"Missing webhook signature\"}");
                return;
            }
            var prefix = Encoding.UTF8.GetBytes(sequenceGuid + " ");
            var signedPayload = new byte[prefix.Length + rawBody.Length];
            Buffer.BlockCopy(prefix, 0, signedPayload, 0, prefix.Length);
            Buffer.BlockCopy(rawBody, 0, signedPayload, prefix.Length, rawBody.Length);
            byte[] digest;
            using (var hmac = new HMACSHA256(Encoding.UTF8.GetBytes(webhookSecret)))
            {
                digest = hmac.ComputeHash(signedPayload);
            }
            var expectedHmac = BitConverter.ToString(digest).Replace("-", "").ToLowerInvariant();
            if (!string.Equals(expectedHmac, suppliedHmac, StringComparison.OrdinalIgnoreCase))
            {
                context.Response.StatusCode = 401;
                context.Response.ContentType = "application/json";
                context.Response.Write("{\"error\":\"Invalid webhook signature\"}");
                return;
            }
        }

        // Deliveroo must be acknowledged before local order processing.
        // Database errors must never prevent the partner acknowledgement.
        try
        {
                Dictionary<string, object> envelope;
                var order = ExtractOrder(body, out envelope);
                var eventName = envelope.ContainsKey("event") ? Convert.ToString(envelope["event"]) : "";
                var orderId = order == null ? null : Convert.ToString(order["id"]);
                var tabletless = order != null && order.ContainsKey("is_tabletless") && Convert.ToBoolean(order["is_tabletless"]);

                // Persist the raw event and queue the DB save BEFORE any outbound
                // call to Deliveroo's API: quelle possono fallire per conto loro
                // (rete, timeout) e non devono impedire di salvare l'ordine.
                LogWebhook(body, context);

                var queuedOrderId = orderId;
                var queuedBody = body;
                ThreadPool.QueueUserWorkItem(delegate(object state)
                {
                    SaveOrderWithRetry(queuedOrderId, queuedBody);
                }, null);

                if (!string.IsNullOrEmpty(orderId))
                {
                    try
                    {
                        if (string.Equals(eventName, "order.new", StringComparison.OrdinalIgnoreCase))
                        {
                            if (tabletless) AcceptOrder(orderId);
                        }
                        else if (string.Equals(eventName, "order.status_update", StringComparison.OrdinalIgnoreCase) &&
                                 string.Equals(Convert.ToString(order["status"]), "accepted", StringComparison.OrdinalIgnoreCase))
                        {
                            if (!tabletless) SyncOrder(orderId, order);
                        }
                    }
                    catch (Exception ex)
                    {
                        // Una chiamata verso le API Deliveroo puo' fallire senza
                        // impedire il salvataggio dell'ordine, gia' persistito sopra.
                        LogIntegrationError("accept_or_sync order=" + orderId + " " + ex.ToString());
                    }
                }
        }
        catch (Exception ex)
        {
            LogIntegrationError(ex.ToString());
        }

        // Deliveroo requires a completed HTTP 200 response for the webhook.
        Acknowledge(context);
    }

    private bool IsDiagnosticsKeyValid(string key)
    {
        var expected = ConfigurationManager.AppSettings["DeliverooDiagnosticsKey"];
        return !string.IsNullOrEmpty(expected) && string.Equals(key, expected, StringComparison.Ordinal);
    }

    private void WriteDiagnostics(HttpContext context)
    {
        var result = new Dictionary<string, object>();
        try
        {
            using (var connection = GetOpenConnection())
            {
                result["database"] = "connected";
                result["orders"] = Scalar(connection, "SELECT COUNT(*) FROM deliveroo_order");
                result["webhooks"] = Scalar(connection, "SELECT COUNT(*) FROM deliveroo_webhook_log");
            }
            context.Response.StatusCode = 200;
        }
        catch (Exception ex)
        {
            result["database"] = "error";
            result["message"] = ex.Message;
            context.Response.StatusCode = 500;
        }
        context.Response.ContentType = "application/json";
        context.Response.Write(new JavaScriptSerializer().Serialize(result));
    }

    private object Scalar(MySqlConnection connection, string sql)
    {
        using (var command = new MySqlCommand(sql, connection))
        {
            command.CommandTimeout = CommandTimeoutSeconds;
            return command.ExecuteScalar();
        }
    }

    private void Acknowledge(HttpContext context)
    {
        context.Response.StatusCode = 200;
        context.Response.TrySkipIisCustomErrors = true;
        context.Response.ContentType = "application/json";
        context.Response.Write("{\"ok\":true}");
        context.Response.Flush();
        context.ApplicationInstance.CompleteRequest();
    }

    private void LogWebhook(string body, HttpContext context)
    {
        try
        {
            var headers = new StringBuilder();
            foreach (string key in context.Request.Headers.AllKeys)
            {
                if (string.Equals(key, "Authorization", StringComparison.OrdinalIgnoreCase) ||
                    string.Equals(key, "Cookie", StringComparison.OrdinalIgnoreCase)) continue;
                headers.Append(key).Append('=').Append(context.Request.Headers[key]).Append(';');
            }
            using (var connection = GetOpenConnection())
            using (var command = new MySqlCommand(@"
                INSERT INTO deliveroo_webhook_log
                    (received_at_utc, request_path, request_headers, payload, processed)
                VALUES
                    (UTC_TIMESTAMP(), @path, @headers, @payload, 0)", connection))
            {
                command.CommandTimeout = CommandTimeoutSeconds;
                command.Parameters.AddWithValue("@path", context.Request.Path);
                command.Parameters.AddWithValue("@headers", headers.ToString());
                command.Parameters.AddWithValue("@payload", body);
                command.ExecuteNonQuery();
            }
        }
        catch (Exception ex)
        {
            LogIntegrationError("log_webhook " + ex.Message);
        }
    }

    // Funzione comune per scrivere un body su una HttpWebRequest.
    private void WriteRequestBody(HttpWebRequest request, byte[] bodyBytes)
    {
        request.ContentLength = bodyBytes.Length;
        using (var stream = request.GetRequestStream()) stream.Write(bodyBytes, 0, bodyBytes.Length);
    }

    // Funzione comune per ottenere il token OAuth2 (client credentials) da Deliveroo.
    private string GetAccessToken()
    {
        var clientId = ConfigurationManager.AppSettings["DeliverooClientId"];
        var clientSecret = ConfigurationManager.AppSettings["DeliverooClientSecret"];
        var tokenRequest = (HttpWebRequest)WebRequest.Create("https://auth-sandbox.developers.deliveroo.com/oauth2/token");
        tokenRequest.Method = "POST";
        tokenRequest.ContentType = "application/x-www-form-urlencoded";
        var tokenBody = "grant_type=client_credentials&client_id=" + HttpUtility.UrlEncode(clientId) + "&client_secret=" + HttpUtility.UrlEncode(clientSecret);
        WriteRequestBody(tokenRequest, Encoding.UTF8.GetBytes(tokenBody));
        using (var response = (HttpWebResponse)tokenRequest.GetResponse())
        using (var reader = new StreamReader(response.GetResponseStream()))
        {
            var data = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(reader.ReadToEnd());
            return Convert.ToString(data["access_token"]);
        }
    }

    // Funzione comune per costruire una richiesta autenticata verso le API ordini di Deliveroo.
    private HttpWebRequest CreateApiRequest(string relativePath, string method)
    {
        var baseUrl = ConfigurationManager.AppSettings["DeliverooApiBaseUrl"] ?? "https://api-sandbox.developers.deliveroo.com";
        var request = (HttpWebRequest)WebRequest.Create(baseUrl.TrimEnd('/') + relativePath);
        request.Method = method;
        request.ContentType = "application/json";
        request.Headers["Authorization"] = "Bearer " + GetAccessToken();
        return request;
    }

    private void AcceptOrder(string orderId)
    {
        var request = CreateApiRequest("/order/v1/orders/" + HttpUtility.UrlEncode(orderId), "PATCH");
        WriteRequestBody(request, Encoding.UTF8.GetBytes("{\"status\":\"accepted\"}"));
        using (var response = (HttpWebResponse)request.GetResponse()) { }
    }

    private void SyncOrder(string orderId, Dictionary<string, object> order)
    {
        var request = CreateApiRequest("/order/v1/orders/" + HttpUtility.UrlEncode(orderId) + "/sync_status", "POST");
        var body = HasMissingPlu(order)
            ? "{\"status\":\"failed\",\"reason\":\"pos_item_id_not_found\",\"notes\":\"One or more order items or modifiers do not contain a PLU.\",\"occurred_at\":\"" + DateTime.UtcNow.ToString("o") + "\"}"
            : HasMismatchedPlu(order)
            ? "{\"status\":\"failed\",\"reason\":\"pos_item_id_mismatched\",\"notes\":\"One or more order items or modifiers do not match the configured Deliveroo menu mapping.\",\"occurred_at\":\"" + DateTime.UtcNow.ToString("o") + "\"}"
            : "{\"status\":\"succeeded\",\"reason\":null,\"notes\":\"Order received by POS\",\"occurred_at\":\"" + DateTime.UtcNow.ToString("o") + "\"}";
        WriteRequestBody(request, Encoding.UTF8.GetBytes(body));
        LogIntegrationError("sync_status_payload " + orderId + " " + body);
        try
        {
            using (var response = (HttpWebResponse)request.GetResponse())
            {
                LogIntegrationError("sync_status " + orderId + " HTTP " + (int)response.StatusCode);
            }
        }
        catch (WebException ex)
        {
            var http = ex.Response as HttpWebResponse;
            var detail = ex.Message;
            if (http != null)
            {
                using (var reader = new StreamReader(http.GetResponseStream())) detail += " HTTP " + (int)http.StatusCode + " " + reader.ReadToEnd();
            }
            LogIntegrationError("sync_status " + orderId + " " + detail);
        }
    }

    private void QueuePrepStages(string orderId)
    {
        ThreadPool.QueueUserWorkItem(delegate(object state)
        {
            try { SendPrepStages(Convert.ToString(state)); }
            catch (Exception ex) { LogIntegrationError("prep_stage_worker " + orderId + " " + ex.Message); }
        }, orderId);
    }

    private void SendPrepStages(string orderId)
    {
        LogIntegrationError("prep_stage_enter " + orderId);
        var stages = new[] { "in_kitchen", "ready_for_collection_soon", "ready_for_collection", "collected" };
        foreach (var stage in stages)
        {
            // Le fasi rappresentano avanzamenti distinti: lasciare qualche
            // secondo tra le chiamate evita di inviarle tutte nello stesso istante.
            if (!string.Equals(stage, "in_kitchen", StringComparison.Ordinal))
                Thread.Sleep(20000);
            var request = CreateApiRequest("/order/v1/orders/" + HttpUtility.UrlEncode(orderId) + "/prep_stage", "POST");
            var body = "{\"stage\":\"" + stage + "\",\"occurred_at\":\"" + DateTime.UtcNow.ToString("o") + "\"}";
            WriteRequestBody(request, Encoding.UTF8.GetBytes(body));
            try
            {
                using (var response = (HttpWebResponse)request.GetResponse())
                    LogIntegrationError("prep_stage " + orderId + " " + stage + " HTTP " + (int)response.StatusCode);
            }
            catch (WebException ex)
            {
                LogIntegrationError("prep_stage " + orderId + " " + stage + " " + ex.Message);
                break;
            }
        }
    }

    private bool HasMissingPlu(Dictionary<string, object> order)
    {
        var items = order == null || !order.ContainsKey("items") ? null : order["items"] as IList;
        if (items == null) return false;
        for (var i = 0; i < items.Count; i++)
        {
            var item = items[i] as Dictionary<string, object>;
            if (item == null || !item.ContainsKey("pos_item_id") || string.IsNullOrEmpty(Convert.ToString(item["pos_item_id"]))) return true;
            var modifiers = item.ContainsKey("modifiers") ? item["modifiers"] as IList : null;
            if (modifiers == null) continue;
            for (var j = 0; j < modifiers.Count; j++)
            {
                var modifier = modifiers[j] as Dictionary<string, object>;
                if (modifier == null || !modifier.ContainsKey("pos_item_id") || string.IsNullOrEmpty(Convert.ToString(modifier["pos_item_id"]))) return true;
            }
        }
        return false;
    }

    private bool HasMismatchedPlu(Dictionary<string, object> order)
    {
        var items = order == null || !order.ContainsKey("items") ? null : order["items"] as IList;
        if (items == null) return false;
        try
        {
            using (var connection = GetOpenConnection())
            {
                var productNames = new Dictionary<int, string>();
                var ingredientIds = new List<int>();
                var ingredientNames = new Dictionary<int, string>();
                var itemPairs = new List<string>();
                var modifierPairs = new List<string>();
                for (var i = 0; i < items.Count; i++)
                {
                    var item = items[i] as Dictionary<string, object>;
                    if (item == null) continue;
                    var itemId = Convert.ToString(item["pos_item_id"]);
                    int productId;
                    if (TryGetConventionId(itemId, "MU", out productId))
                    {
                        productNames[productId] = GetPayloadName(item);
                    }
                    else itemPairs.Add(itemId);

                    var modifiers = item.ContainsKey("modifiers") ? item["modifiers"] as IList : null;
                    if (modifiers == null) continue;
                    for (var j = 0; j < modifiers.Count; j++)
                    {
                        var modifier = modifiers[j] as Dictionary<string, object>;
                        if (modifier == null) continue;
                        var modifierId = Convert.ToString(modifier["pos_item_id"]);
                        int ingredientId;
                        if (TryGetConventionId(modifierId, "OM", out ingredientId))
                        {
                            ingredientIds.Add(ingredientId);
                            ingredientNames[ingredientId] = GetPayloadName(modifier);
                        }
                        else modifierPairs.Add(itemId + "\u001f" + modifierId);
                    }
                }
                if (!AllNamesMatch(connection, "v2_products", "name", productNames, "product_name")) return true;
                if (!AllIdsFound(connection, "v2_ingredients", ingredientIds, "ingredient")) return true;
                if (!AllNamesMatch(connection, "v2_ingredients", "name_it", ingredientNames, "ingredient_name")) return true;
                foreach (var itemId in itemPairs)
                    if (!MappingExists(connection, itemId, null, order)) return true;
                foreach (var pair in modifierPairs)
                {
                    var parts = pair.Split(new[] { '\u001f' });
                    if (!MappingExists(connection, parts[0], parts[1], order)) return true;
                }
            }
        }
        catch (Exception ex) { LogProcess("ERROR", "plu_mapping_check " + ex.Message); }
        return false;
    }

    private bool TryGetConventionId(string value, string prefix, out int id)
    {
        id = 0;
        if (string.IsNullOrEmpty(value) || !value.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) return false;
        return Int32.TryParse(value.Substring(prefix.Length), out id) && id > 0;
    }

    private string GetPayloadName(Dictionary<string, object> value)
    {
        if (value == null) return "";
        if (value.ContainsKey("name")) return Convert.ToString(value["name"]);
        return value.ContainsKey("operational_name") ? Convert.ToString(value["operational_name"]) : "";
    }

    private bool AllNamesMatch(MySqlConnection connection, string table, string nameColumn,
        Dictionary<int, string> expected, string parameterPrefix)
    {
        if (expected.Count == 0) return true;
        var parameters = new List<string>();
        using (var command = new MySqlCommand())
        {
            command.Connection = connection;
            command.CommandTimeout = CommandTimeoutSeconds;
            var index = 0;
            foreach (var pair in expected)
            {
                var parameter = "@" + parameterPrefix + index++;
                parameters.Add(parameter);
                command.Parameters.AddWithValue(parameter, pair.Key);
            }
            command.CommandText = "SELECT id, " + nameColumn + " FROM " + table +
                " WHERE id IN (" + string.Join(",", parameters.ToArray()) + ") ORDER BY id ASC";
            using (var reader = command.ExecuteReader())
            {
                var found = new Dictionary<int, string>();
                while (reader.Read()) found[Convert.ToInt32(reader["id"])] = Convert.ToString(reader[nameColumn]);
                foreach (var pair in expected)
                    if (!found.ContainsKey(pair.Key) || !NamesEqual(found[pair.Key], pair.Value)) return false;
            }
        }
        return true;
    }

    private bool AllIdsFound(MySqlConnection connection, string table, List<int> ids, string parameterPrefix)
    {
        if (ids.Count == 0) return true;
        var uniqueIds = new List<int>();
        foreach (var id in ids)
            if (!uniqueIds.Contains(id)) uniqueIds.Add(id);
        var parameters = new List<string>();
        using (var command = new MySqlCommand())
        {
            command.Connection = connection;
            command.CommandTimeout = CommandTimeoutSeconds;
            for (var i = 0; i < uniqueIds.Count; i++)
            {
                var name = "@" + parameterPrefix + i;
                parameters.Add(name);
                command.Parameters.AddWithValue(name, uniqueIds[i]);
            }
            command.CommandText = "SELECT id FROM " + table + " WHERE id IN (" +
                string.Join(",", parameters.ToArray()) + ") ORDER BY id ASC";
            using (var reader = command.ExecuteReader())
            {
                var found = 0;
                while (reader.Read()) found++;
                return found == uniqueIds.Count;
            }
        }
    }

    private bool NamesEqual(string left, string right)
    {
        return string.Equals((left ?? "").Trim(), (right ?? "").Trim(), StringComparison.OrdinalIgnoreCase);
    }

    private bool MappingExists(MySqlConnection connection, string itemId, string modifierId, Dictionary<string, object> order)
    {
        using (var command = new MySqlCommand(@"
            SELECT COUNT(*) FROM deliveroo_menu_mapping
            WHERE site_id = @site AND deliveroo_item_id = @item
              AND ((@modifier IS NULL AND deliveroo_modifier_id IS NULL)
                OR (@modifier IS NOT NULL AND deliveroo_modifier_id = @modifier))
              AND active = 1", connection))
        {
            command.CommandTimeout = CommandTimeoutSeconds;
            command.Parameters.AddWithValue("@site", order.ContainsKey("location_id") ? Convert.ToString(order["location_id"]) : "");
            command.Parameters.AddWithValue("@item", itemId);
            command.Parameters.AddWithValue("@modifier", string.IsNullOrEmpty(modifierId) ? (object)DBNull.Value : modifierId);
            return Convert.ToInt32(command.ExecuteScalar()) > 0;
        }
    }

    private void LogIntegrationError(string message)
    {
        LogProcess("ERROR", message);
    }

    // Funzione comune di logging su deliveroo_process_log, con livello parametrico
    // cosi' possiamo tracciare anche i successi (INFO) e non solo gli errori.
    private void LogProcess(string level, string message)
    {
        try
        {
            using (var connection = GetOpenConnection())
            using (var command = new MySqlCommand(@"INSERT INTO deliveroo_process_log
                (created_at_utc, log_level, message)
                VALUES (UTC_TIMESTAMP(), @level, @message)", connection))
            {
                command.CommandTimeout = CommandTimeoutSeconds;
                command.Parameters.AddWithValue("@level", level);
                command.Parameters.AddWithValue("@message", message);
                command.ExecuteNonQuery();
            }
        }
        catch { }
    }

    private bool SaveOrder(string body)
    {
        var stage = "deserialize";
        string orderId = null;
        var stopwatch = Stopwatch.StartNew();
        try
        {
            Dictionary<string, object> envelope;
            var order = ExtractOrder(body, out envelope);
            if (order == null || !order.ContainsKey("id")) return true; // nulla da salvare, non e' un errore da ritentare
            orderId = Convert.ToString(order["id"]);
            var eventName = envelope.ContainsKey("event") ? Convert.ToString(envelope["event"]) : "";

            var isNewOrder = string.Equals(eventName, "order.new", StringComparison.OrdinalIgnoreCase);

            stage = "open_connection";
            using (var connection = GetOpenConnection())
            {
                if (isNewOrder)
                {
                    // Prima registrazione dell'ordine. INSERT IGNORE assorbe
                    // eventuali redelivery duplicate dello stesso evento order.new.
                    stage = "order_insert";
                    using (var command = new MySqlCommand(@"
                        INSERT IGNORE INTO deliveroo_order (external_order_id, order_payload)
                        VALUES (@id, @payload)", connection))
                    {
                        command.CommandTimeout = CommandTimeoutSeconds;
                        command.Parameters.AddWithValue("@id", orderId);
                        command.Parameters.AddWithValue("@payload", body);
                        command.ExecuteNonQuery();
                    }
                }
                else
                {
                    // Evento successivo alla creazione: la riga deve gia' esistere,
                    // quindi un semplice UPDATE sul payload basta.
                    stage = "order_update";
                    int rowsAffected;
                    using (var command = new MySqlCommand(@"
                        UPDATE deliveroo_order SET order_payload = @payload
                        WHERE external_order_id = @id", connection))
                    {
                        command.CommandTimeout = CommandTimeoutSeconds;
                        command.Parameters.AddWithValue("@id", orderId);
                        command.Parameters.AddWithValue("@payload", body);
                        rowsAffected = command.ExecuteNonQuery();
                    }
                    if (rowsAffected == 0)
                    {
                        // La riga non esisteva ancora (es. order.new perso o
                        // arrivato dopo questo evento): la creiamo comunque
                        // per non perdere i dati dell'ordine.
                        stage = "order_insert_fallback";
                        using (var command = new MySqlCommand(@"
                            INSERT IGNORE INTO deliveroo_order (external_order_id, order_payload)
                            VALUES (@id, @payload)", connection))
                        {
                            command.CommandTimeout = CommandTimeoutSeconds;
                            command.Parameters.AddWithValue("@id", orderId);
                            command.Parameters.AddWithValue("@payload", body);
                            command.ExecuteNonQuery();
                        }
                    }
                }
            }
            stopwatch.Stop();
            LogProcess("INFO", "save_order success order=" + orderId +
                " event=" + eventName +
                " elapsed_ms=" + stopwatch.ElapsedMilliseconds);
            return true;
        }
        catch (MySqlException ex)
        {
            stopwatch.Stop();
            LogIntegrationError("save_order stage=" + stage +
                " order=" + orderId +
                " mysql_number=" + ex.Number +
                " elapsed_ms=" + stopwatch.ElapsedMilliseconds +
                " message=" + ex.Message);
            return false;
        }
        catch (Exception ex)
        {
            stopwatch.Stop();
            LogIntegrationError("save_order stage=" + stage +
                " order=" + orderId +
                " type=" + ex.GetType().FullName +
                " elapsed_ms=" + stopwatch.ElapsedMilliseconds +
                " message=" + ex.Message);
            return false;
        }
    }

    private void SaveOrderWithRetry(string orderId, string body)
    {
        LogProcess("INFO", "save_order_with_retry queued order=" + orderId);
        // *** LOCK TEMPORANEAMENTE DISATTIVATO PER TEST (26/07) ***
        // Rimosso apposta per isolare se il problema di timeout sia legato al
        // lock/contesa sulla riga, o indipendente da esso. Da rimettere con
        // attenzione una volta capita la causa - vedi GetOrderLock/OrderLocks
        // ancora presenti in fondo al file, pronte per essere riattivate.
        for (var attempt = 0; attempt < 3; attempt++)
        {
            if (SaveOrder(body)) return;
            if (attempt < 2) Thread.Sleep(1500);
        }
    }

}
