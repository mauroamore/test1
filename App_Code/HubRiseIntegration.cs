using System;
using System.Collections;
using System.Collections.Generic;
using System.Configuration;
using System.Net;
using System.Text;
using System.Text.RegularExpressions;
using System.Web;
using System.Web.Script.Serialization;
using MySql.Data.MySqlClient;

/// <summary>
/// Shared production-safe plumbing for HubRise handlers. Independent from DeliverooIntegration.cs
/// by design (separate integration, built from scratch). Every HubRise handler must call into this
/// class rather than duplicating DB/HTTP logic locally.
/// </summary>
public static class HubRiseIntegration
{
    public const int ConnectionTimeoutSeconds = 15;
    public const int CommandTimeoutSeconds = 25;

    public static string ApiBaseUrl
    {
        get { return (ConfigurationManager.AppSettings["HubRiseApiBaseUrl"] ?? "https://api.hubrise.com/v1").TrimEnd('/'); }
    }

    public static string ManagerBaseUrl
    {
        get { return (ConfigurationManager.AppSettings["HubRiseManagerBaseUrl"] ?? "https://manager.hubrise.com").TrimEnd('/'); }
    }

    public static MySqlConnection OpenDatabase()
    {
        var configured = ConfigurationManager.ConnectionStrings["MySqlConnectionString"];
        if (configured == null || string.IsNullOrWhiteSpace(configured.ConnectionString))
            throw new ConfigurationErrorsException("MySqlConnectionString is not configured.");

        var builder = new MySqlConnectionStringBuilder(configured.ConnectionString);
        builder.ConnectionTimeout = ConnectionTimeoutSeconds;
        // Queste chiamate sono rare e sparse nel tempo: una connessione presa dal pool puo'
        // essere gia' stata chiusa lato server (wait_timeout) senza che il pool se ne accorga,
        // causando un SocketException al primo utilizzo. Niente pooling = sempre connessione fresca.
        builder.Pooling = false;
        var connection = new MySqlConnection(builder.ConnectionString);
        connection.Open();
        return connection;
    }

    public class HubRiseConnectionInfo
    {
        public string AccessToken;
        public string AccountId;
        public string LocationId;
        public string CatalogId;
        public string CustomerListId;
    }

    /// <summary>
    /// HubRise access tokens do not expire and there is no refresh flow, so unlike Deliveroo's
    /// client-credentials handshake this just reads the token stored by HubRiseConnect.ashx.
    /// </summary>
    public static HubRiseConnectionInfo GetConnection()
    {
        using (var connection = OpenDatabase())
        using (var command = new MySqlCommand(@"
            SELECT access_token, account_id, location_id, catalog_id, customer_list_id
            FROM hubrise_connection
            WHERE revoked_at_utc IS NULL
            ORDER BY id DESC
            LIMIT 1", connection))
        {
            command.CommandTimeout = CommandTimeoutSeconds;
            using (var reader = command.ExecuteReader())
            {
                if (!reader.Read())
                    throw new InvalidOperationException("Nessuna connessione HubRise attiva. Eseguire prima HubRiseConnect.ashx.");

                return new HubRiseConnectionInfo
                {
                    AccessToken = Convert.ToString(reader["access_token"]),
                    AccountId = reader["account_id"] as string,
                    LocationId = reader["location_id"] as string,
                    CatalogId = reader["catalog_id"] as string,
                    CustomerListId = reader["customer_list_id"] as string
                };
            }
        }
    }

    public static HttpWebRequest CreateApiRequest(string url, string method)
    {
        var connectionInfo = GetConnection();
        var request = (HttpWebRequest)WebRequest.Create(url);
        request.Method = method;
        request.Accept = "application/json";
        request.ContentType = "application/json";
        request.Timeout = 15000;
        request.ReadWriteTimeout = 15000;
        request.Headers["X-Access-Token"] = connectionInfo.AccessToken;
        return request;
    }

    public static void LogProcess(string level, string message)
    {
        try
        {
            using (var connection = OpenDatabase())
            using (var command = new MySqlCommand(
                "INSERT INTO hubrise_process_log (log_level, message) VALUES (@level, @message)", connection))
            {
                command.CommandTimeout = CommandTimeoutSeconds;
                command.Parameters.AddWithValue("@level", level);
                command.Parameters.AddWithValue("@message", message);
                command.ExecuteNonQuery();
            }
        }
        catch
        {
            // Logging must never throw and take down a caller that is trying to report an error.
        }
    }

    /// <summary>
    /// Single upsert routine for HubRise order events, shared by HubRiseWebhook.ashx today and by
    /// any future passive-polling handler, so the persistence logic lives in exactly one place.
    /// </summary>
    public static void SaveOrder(string rawBody)
    {
        var serializer = new JavaScriptSerializer();
        Dictionary<string, object> payload;
        try
        {
            payload = serializer.Deserialize<Dictionary<string, object>>(rawBody);
        }
        catch (Exception ex)
        {
            LogProcess("ERROR", "HubRise: payload webhook non e' un JSON valido: " + ex.Message);
            throw;
        }

        var orderNode = ExtractOrderNode(payload);
        if (orderNode == null)
        {
            LogProcess("WARN", "HubRise: webhook senza nodo ordine riconoscibile.");
            return;
        }

        var externalOrderId = GetString(orderNode, "id") ?? GetString(payload, "order_id") ?? GetString(orderNode, "ref");
        if (string.IsNullOrWhiteSpace(externalOrderId))
        {
            LogProcess("WARN", "HubRise: ordine senza id/ref, payload scartato.");
            return;
        }

        var locationId = GetString(payload, "location_id") ?? GetString(orderNode, "location_id");
        var status = GetString(orderNode, "status");
        var serviceType = GetString(orderNode, "service_type");
        var customerName = ExtractCustomerName(orderNode);
        var totalFractional = ExtractTotalFractional(orderNode);
        var currencyCode = GetCurrencyCode(orderNode, "total");
        // Codice che il rider/cliente comunica in ritiro per farsi riconoscere l'ordine.
        var collectionCode = GetString(orderNode, "collection_code");
        // Piattaforma di origine (Deliveroo, JustEat, Glovo, UberEats...).
        var channel = GetString(orderNode, "channel");

        // Niente MySqlTransaction esplicita: su questo hosting (Aruba, MySQL condiviso dietro
        // un proxy) una transazione multi-statement lato client blocca indefinitamente la
        // connessione fino al timeout. Ogni singola INSERT/DELETE resta comunque atomica di
        // per se' in InnoDB anche in autocommit; si perde solo l'atomicita' "tutto o niente"
        // fra le varie tabelle, accettabile dato che HubRise reinvia lo stato intero a ogni
        // create/update.
        // external_order.order_payload is the canonical order document, not the HubRise
        // webhook envelope. Keeping new_state here makes generated columns and items resolve
        // from the same shape used by the rest of the external-order pipeline.
        var canonicalOrderPayload = serializer.Serialize(orderNode);
        using (var connection = OpenDatabase())
        {
            UpsertOrder(connection, externalOrderId, locationId, status, serviceType,
                customerName, totalFractional, currencyCode, collectionCode, channel, canonicalOrderPayload);
        }

        // Solo alla creazione (non ai successivi "update", per non riconfermare piu' volte lo
        // stesso ordine): se tutti i ref articolo corrispondono a prodotti reali del catalogo,
        // confermiamo automaticamente a HubRise che l'ordine e' arrivato ("received"). "received"
        // non equivale ad "accettato": e' solo l'ack di ricezione, l'accettazione vera resta un
        // passo separato (quando l'operatore manda l'ordine in cucina).
        var eventType = GetString(payload, "event_type");
        if (string.Equals(eventType, "create", StringComparison.OrdinalIgnoreCase))
        {
            ConfirmReceivedIfValid(externalOrderId);
        }
    }

    private static void ConfirmReceivedIfValid(string externalOrderId)
    {
        try
        {
            using (var connection = OpenDatabase())
            {
                if (!AllItemRefsResolveToRealProducts(connection, externalOrderId))
                {
                    LogProcess("WARN", "HubRise: ordine " + externalOrderId +
                        " ha almeno un articolo con ref non riconosciuto nel catalogo: nessuna conferma automatica, richiede verifica manuale.");
                    return;
                }
            }
            UpdateOrderStatus(externalOrderId, "received");
        }
        catch (Exception ex)
        {
            LogProcess("ERROR", "HubRise: conferma automatica 'received' fallita per " + externalOrderId + ": " + ex);
        }
    }

    private static bool AllItemRefsResolveToRealProducts(MySqlConnection connection, string externalOrderId)
    {
        var refs = new List<string>();
        using (var command = new MySqlCommand(
            "SELECT order_payload FROM external_order WHERE source = 'hubrise' AND external_order_id = @externalOrderId", connection))
        {
            command.CommandTimeout = CommandTimeoutSeconds;
            command.Parameters.AddWithValue("@externalOrderId", externalOrderId);
            using (var reader = command.ExecuteReader())
            {
                if (reader.Read())
                {
                    var payload = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(reader["order_payload"].ToString());
                    var savedOrder = ExtractOrderNode(payload);
                    foreach (var rawItem in GetList(savedOrder, "items") ?? new List<object>())
                    {
                        var item = rawItem as Dictionary<string, object>;
                        if (item != null) refs.Add(GetString(item, "sku_ref") ?? GetString(item, "sku") ?? GetString(item, "ref"));
                    }
                }
            }
        }
        if (refs.Count == 0) return false;

        var productIds = new List<int>();
        foreach (var reference in refs)
        {
            var match = Regex.Match(reference ?? "", "^P(\\d+)$");
            if (!match.Success) return false;
            productIds.Add(int.Parse(match.Groups[1].Value));
        }

        var placeholders = new List<string>();
        using (var command = connection.CreateCommand())
        {
            command.CommandTimeout = CommandTimeoutSeconds;
            for (var i = 0; i < productIds.Count; i++)
            {
                var paramName = "@id" + i;
                placeholders.Add(paramName);
                command.Parameters.AddWithValue(paramName, productIds[i]);
            }
            command.CommandText = @"
                SELECT COUNT(*) FROM v2_products
                WHERE is_active = 1 AND is_delivery = 1 AND id IN (" + string.Join(",", placeholders) + ")";
            var matchCount = Convert.ToInt32(command.ExecuteScalar());
            return matchCount == productIds.Count;
        }
    }

    // Chiamata anche dagli endpoint che reagiscono alle azioni dell'operatore (manda in cucina,
    // consegnato): aggiorna sia HubRise che la nostra copia locale dello stato.
    public static void UpdateOrderStatus(string externalOrderId, string status, string confirmedTime = null)
    {
        var connectionInfo = GetConnection();
        var url = ApiBaseUrl + "/locations/" + HttpUtility.UrlEncode(connectionInfo.LocationId) +
            "/orders/" + HttpUtility.UrlEncode(externalOrderId);
        var request = CreateApiRequest(url, "PATCH");
        var payloadFields = new Dictionary<string, object> { { "status", status } };
        // confirmed_time sovrascrive l'expected_time del cliente/piattaforma: usato quando la
        // cucina prevede di metterci piu' (o meno) tempo di quanto originariamente proposto.
        if (!string.IsNullOrWhiteSpace(confirmedTime)) payloadFields["confirmed_time"] = confirmedTime;
        var payload = new JavaScriptSerializer().Serialize(payloadFields);
        var bytes = Encoding.UTF8.GetBytes(payload);
        request.ContentLength = bytes.Length;
        using (var stream = request.GetRequestStream()) stream.Write(bytes, 0, bytes.Length);
        using (var response = (HttpWebResponse)request.GetResponse()) { }

        using (var connection = OpenDatabase())
        using (var command = new MySqlCommand(
            "UPDATE external_order SET status = @status, updated_at_utc = UTC_TIMESTAMP() WHERE source = 'hubrise' AND external_order_id = @externalOrderId", connection))
        {
            command.CommandTimeout = CommandTimeoutSeconds;
            command.Parameters.AddWithValue("@status", status);
            command.Parameters.AddWithValue("@externalOrderId", externalOrderId);
            command.ExecuteNonQuery();
        }

        LogProcess("INFO", "HubRise: stato ordine " + externalOrderId + " aggiornato a '" + status + "'.");
    }

    // Niente "INSERT ... ON DUPLICATE KEY UPDATE": su questo hosting il driver .NET si blocca
    // in lettura subito dopo che il comando e' gia' andato a buon fine lato server (probabilmente
    // per come interpreta il messaggio informativo extra che MySQL restituisce solo per questa
    // sintassi). Un UPDATE semplice, con INSERT solo se non tocca nessuna riga, evita del tutto
    // quella sintassi e si comporta come le altre INSERT/DELETE di questo file, che non si sono
    // mai bloccate.
    private static void UpsertOrder(MySqlConnection connection, string externalOrderId,
        string locationId, string status, string serviceType, string customerName, long? totalFractional,
        string currencyCode, string collectionCode, string channel, string rawBody)
    {
        int rowsUpdated;
        using (var update = new MySqlCommand(@"
            UPDATE external_order SET
                order_payload = @orderPayload,
                channel = @channel,
                updated_at_utc = UTC_TIMESTAMP()
            WHERE source = 'hubrise' AND external_order_id = @externalOrderId", connection))
        {
            update.CommandTimeout = CommandTimeoutSeconds;
            update.Parameters.AddWithValue("@externalOrderId", externalOrderId);
            update.Parameters.AddWithValue("@channel", (object)channel ?? DBNull.Value);
            update.Parameters.AddWithValue("@orderPayload", rawBody);
            rowsUpdated = update.ExecuteNonQuery();
        }

        if (rowsUpdated > 0) return;

        using (var insert = new MySqlCommand(@"
            INSERT INTO external_order
                (source, channel, order_payload, first_received_at_utc, updated_at_utc)
            VALUES
                ('hubrise', @channel, @orderPayload, UTC_TIMESTAMP(), UTC_TIMESTAMP())", connection))
        {
            insert.CommandTimeout = CommandTimeoutSeconds;
            insert.Parameters.AddWithValue("@channel", (object)channel ?? DBNull.Value);
            insert.Parameters.AddWithValue("@orderPayload", rawBody);
            insert.ExecuteNonQuery();
        }
    }

    private static void SaveItems(MySqlConnection connection, string externalOrderId,
        Dictionary<string, object> orderNode)
    {
        using (var deleteOptions = new MySqlCommand(
            "DELETE FROM hubrise_order_option WHERE external_order_id = @externalOrderId", connection))
        {
            deleteOptions.CommandTimeout = CommandTimeoutSeconds;
            deleteOptions.Parameters.AddWithValue("@externalOrderId", externalOrderId);
            deleteOptions.ExecuteNonQuery();
        }
        using (var deleteItems = new MySqlCommand(
            "DELETE FROM hubrise_order_item WHERE external_order_id = @externalOrderId", connection))
        {
            deleteItems.CommandTimeout = CommandTimeoutSeconds;
            deleteItems.Parameters.AddWithValue("@externalOrderId", externalOrderId);
            deleteItems.ExecuteNonQuery();
        }

        var items = GetList(orderNode, "items");
        if (items == null) return;

        var serializer = new JavaScriptSerializer();
        var lineNumber = 0;
        foreach (var rawItem in items)
        {
            var item = rawItem as Dictionary<string, object>;
            if (item == null) continue;
            lineNumber++;

            var itemName = GetString(item, "product_name") ?? GetString(item, "name");
            var hubriseRef = GetString(item, "sku_ref") ?? GetString(item, "sku") ?? GetString(item, "ref");
            var quantity = GetDecimal(item, "quantity") ?? 1m;
            var unitPriceFractional = ToFractional(GetDecimal(item, "price"));
            var totalPriceFractional = unitPriceFractional.HasValue
                ? (long?)Math.Round(unitPriceFractional.Value * quantity)
                : null;
            var options = GetList(item, "options");
            var optionsJson = options != null ? serializer.Serialize(options) : null;

            using (var command = new MySqlCommand(@"
                INSERT INTO hubrise_order_item
                    (external_order_id, line_number, hubrise_ref, item_name, quantity,
                     unit_price_fractional, total_price_fractional, options_json, item_payload)
                VALUES
                    (@externalOrderId, @lineNumber, @hubriseRef, @itemName, @quantity,
                     @unitPriceFractional, @totalPriceFractional, @optionsJson, @itemPayload)", connection))
            {
                command.CommandTimeout = CommandTimeoutSeconds;
                command.Parameters.AddWithValue("@externalOrderId", externalOrderId);
                command.Parameters.AddWithValue("@lineNumber", lineNumber);
                command.Parameters.AddWithValue("@hubriseRef", (object)hubriseRef ?? DBNull.Value);
                command.Parameters.AddWithValue("@itemName", (object)itemName ?? DBNull.Value);
                command.Parameters.AddWithValue("@quantity", quantity);
                command.Parameters.AddWithValue("@unitPriceFractional", (object)unitPriceFractional ?? DBNull.Value);
                command.Parameters.AddWithValue("@totalPriceFractional", (object)totalPriceFractional ?? DBNull.Value);
                command.Parameters.AddWithValue("@optionsJson", (object)optionsJson ?? DBNull.Value);
                command.Parameters.AddWithValue("@itemPayload", serializer.Serialize(item));
                command.ExecuteNonQuery();
            }

            if (options == null) continue;
            var optionNumber = 0;
            foreach (var rawOption in options)
            {
                var option = rawOption as Dictionary<string, object>;
                if (option == null) continue;
                optionNumber++;

                var optionName = GetString(option, "name");
                var optionRef = GetString(option, "sku") ?? GetString(option, "ref");
                var optionQuantity = GetDecimal(option, "quantity") ?? 1m;
                var optionPriceFractional = ToFractional(GetDecimal(option, "price"));

                using (var command = new MySqlCommand(@"
                    INSERT INTO hubrise_order_option
                        (external_order_id, line_number, option_number, hubrise_ref, option_name,
                         quantity, price_fractional, option_payload)
                    VALUES
                        (@externalOrderId, @lineNumber, @optionNumber, @hubriseRef, @optionName,
                         @quantity, @priceFractional, @optionPayload)", connection))
                {
                    command.CommandTimeout = CommandTimeoutSeconds;
                    command.Parameters.AddWithValue("@externalOrderId", externalOrderId);
                    command.Parameters.AddWithValue("@lineNumber", lineNumber);
                    command.Parameters.AddWithValue("@optionNumber", optionNumber);
                    command.Parameters.AddWithValue("@hubriseRef", (object)optionRef ?? DBNull.Value);
                    command.Parameters.AddWithValue("@optionName", (object)optionName ?? DBNull.Value);
                    command.Parameters.AddWithValue("@quantity", optionQuantity);
                    command.Parameters.AddWithValue("@priceFractional", (object)optionPriceFractional ?? DBNull.Value);
                    command.Parameters.AddWithValue("@optionPayload", serializer.Serialize(option));
                    command.ExecuteNonQuery();
                }
            }
        }
    }

    private static Dictionary<string, object> ExtractOrderNode(Dictionary<string, object> payload)
    {
        if (payload == null) return null;

        // Confirmed HubRise callback envelope: {id, resource_type, event_type, created_at,
        // order_id, location_id, previous_state, new_state}. The full order lives in
        // new_state for create/update events (the only ones this integration registers for).
        var resourceType = GetString(payload, "resource_type");
        if (resourceType != null && !string.Equals(resourceType, "order", StringComparison.OrdinalIgnoreCase))
            return null;

        object newState;
        if (payload.TryGetValue("new_state", out newState))
        {
            var nested = newState as Dictionary<string, object>;
            if (nested != null) return nested;
        }

        // Fallbacks in case an older/different envelope shape shows up.
        object orderValue;
        if (payload.TryGetValue("order", out orderValue))
        {
            var nested = orderValue as Dictionary<string, object>;
            if (nested != null) return nested;
        }
        return payload.ContainsKey("status") || payload.ContainsKey("items") ? payload : null;
    }

    private static string ExtractCustomerName(Dictionary<string, object> orderNode)
    {
        object customerValue;
        if (!orderNode.TryGetValue("customer", out customerValue)) return null;
        var customer = customerValue as Dictionary<string, object>;
        if (customer == null) return null;
        var name = GetString(customer, "name");
        if (!string.IsNullOrWhiteSpace(name)) return name;
        var firstName = GetString(customer, "first_name");
        var lastName = GetString(customer, "last_name");
        return string.IsNullOrWhiteSpace(firstName) && string.IsNullOrWhiteSpace(lastName)
            ? null
            : (firstName + " " + lastName).Trim();
    }

    private static long? ExtractTotalFractional(Dictionary<string, object> orderNode)
    {
        var total = GetDecimal(orderNode, "total") ?? GetDecimal(orderNode, "total_amount");
        return ToFractional(total);
    }

    private static long? ToFractional(decimal? amount)
    {
        return amount.HasValue ? (long?)Math.Round(amount.Value * 100m) : null;
    }

    private static string GetString(Dictionary<string, object> node, string key)
    {
        object value;
        if (node == null || !node.TryGetValue(key, out value) || value == null) return null;
        return Convert.ToString(value);
    }

    // HubRise esprime gli importi come testo "12.34 EUR", non come numero puro: si isola la
    // parte numerica iniziale prima di interpretarla, altrimenti il parsing fallisce sempre.
    private static decimal? GetDecimal(Dictionary<string, object> node, string key)
    {
        object value;
        if (node == null || !node.TryGetValue(key, out value) || value == null) return null;
        var match = Regex.Match(Convert.ToString(value), @"-?\d+(\.\d+)?");
        if (!match.Success) return null;
        decimal result;
        return decimal.TryParse(match.Value, System.Globalization.NumberStyles.Any,
            System.Globalization.CultureInfo.InvariantCulture, out result)
            ? (decimal?)result
            : null;
    }

    private static string GetCurrencyCode(Dictionary<string, object> node, string key)
    {
        object value;
        if (node == null || !node.TryGetValue(key, out value) || value == null) return null;
        var match = Regex.Match(Convert.ToString(value), "([A-Z]{3})\\s*$");
        return match.Success ? match.Groups[1].Value : null;
    }

    // JavaScriptSerializer rappresenta gli array JSON come ArrayList, non come List<object>:
    // un cast diretto con "as List<object>" fallisce silenziosamente (torna null) e fa sparire
    // articoli/opzioni senza errori. Si converte esplicitamente elemento per elemento.
    private static List<object> GetList(Dictionary<string, object> node, string key)
    {
        object value;
        if (node == null || !node.TryGetValue(key, out value) || value == null) return null;
        var enumerable = value as IEnumerable;
        if (enumerable == null) return null;
        var list = new List<object>();
        foreach (var element in enumerable) list.Add(element);
        return list;
    }
}
