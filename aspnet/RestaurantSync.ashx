<%@ WebHandler Language="C#" Class="RestaurantSync" %>

using System;
using System.Collections.Generic;
using System.Configuration;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Web;
using System.Web.Script.Serialization;
using MySql.Data.MySqlClient;

/// <summary>
/// Ponte per un'istanza esterna del software (fuori dalla LAN del ristorante): il locale
/// (server.js) resta l'unica fonte autorevole, spinge qui la sua istantanea completa a intervalli
/// e legge da qui eventuali comandi in coda mandati dall'esterno. Riusa la stessa connessione DB
/// (Pooling=false) e lo stesso idioma "UPDATE poi INSERT solo se 0 righe" gia' validati per
/// HubRise su questo hosting (mai ON DUPLICATE KEY UPDATE).
/// </summary>
public class RestaurantSync : IHttpHandler
{
    private const int CommandTimeoutSeconds = 15;
    private const int MaxPendingCommands = 50;

    public bool IsReusable { get { return false; } }

    public void ProcessRequest(HttpContext context)
    {
        context.Response.ContentType = "application/json";

        var expectedKey = ConfigurationManager.AppSettings["RestaurantSyncKey"];
        var suppliedKey = context.Request.QueryString["key"];
        if (string.IsNullOrEmpty(expectedKey) || !string.Equals(expectedKey, suppliedKey, StringComparison.Ordinal))
        {
            context.Response.StatusCode = 401;
            context.Response.Write("{\"error\":\"Unauthorized\"}");
            return;
        }

        var mode = context.Request.QueryString["mode"];
        try
        {
            switch ((mode ?? "").ToLowerInvariant())
            {
                case "state":
                    GetState(context);
                    return;
                case "push_state":
                    PushState(context);
                    return;
                case "command":
                    SubmitCommand(context);
                    return;
                case "pending_commands":
                    GetPendingCommands(context);
                    return;
                case "ack_commands":
                    AckCommands(context);
                    return;
                case "command_status":
                    GetCommandStatus(context);
                    return;
                case "log_freed":
                    LogFreed(context);
                    return;
                default:
                    context.Response.StatusCode = 400;
                    context.Response.Write("{\"error\":\"mode mancante o non valido\"}");
                    return;
            }
        }
        catch (Exception ex)
        {
            HubRiseIntegration.LogProcess("ERROR", "RestaurantSync: " + ex);
            context.Response.StatusCode = 500;
            context.Response.Write("{\"error\":\"internal_error\"}");
        }
    }

    // GET ?mode=state - ultima istantanea (riga piu' recente = turno corrente), nella stessa forma
    // {"state": {...}} usata da /api/state locale, cosi' il front-end puo' riusare la stessa
    // syncFromServer() senza modifiche. In piu', nella stessa risposta, l'inizio/tipo del turno e
    // l'elenco (JSON) dei liberati in questo turno - il front-end esistente li ignora finche' non li usa.
    private void GetState(HttpContext context)
    {
        using (var connection = HubRiseIntegration.OpenDatabase())
        using (var command = new MySqlCommand(@"
            SELECT s.state_payload, s.turno_start, s.freed_log, t.label AS turno_label
            FROM restaurant_state_snapshot s
            LEFT JOIN restaurant_turno_types t ON t.id = s.turno_type_id
            ORDER BY s.id DESC LIMIT 1", connection))
        {
            command.CommandTimeout = CommandTimeoutSeconds;
            using (var reader = command.ExecuteReader())
            {
                if (!reader.Read())
                {
                    context.Response.Write("{\"state\":null}");
                    return;
                }
                var payload = reader["state_payload"] == DBNull.Value ? null : reader["state_payload"].ToString();
                if (string.IsNullOrEmpty(payload))
                {
                    context.Response.Write("{\"state\":null}");
                    return;
                }
                var turnoStart = reader["turno_start"] == DBNull.Value ? null : Convert.ToDateTime(reader["turno_start"]).ToString("yyyy-MM-ddTHH:mm:ss");
                var turnoLabel = reader["turno_label"] == DBNull.Value ? null : reader["turno_label"].ToString();
                var freedLog = reader["freed_log"] == DBNull.Value ? "[]" : reader["freed_log"].ToString();
                context.Response.Write("{\"state\":" + payload +
                    ",\"turno_start\":" + (turnoStart == null ? "null" : "\"" + turnoStart + "\"") +
                    ",\"turno_label\":" + (turnoLabel == null ? "null" : "\"" + turnoLabel.Replace("\"", "'") + "\"") +
                    ",\"freed_log\":" + freedLog + "}");
            }
        }
    }

    // POST ?mode=push_state - il locale carica qui la sua istantanea autorevole (corpo = lo stesso
    // JSON completo che server.js tiene in sharedState), insieme all'ora locale del ristorante
    // (query string "now", calcolata da server.js: e' l'unica macchina di cui fidarsi per l'ora
    // giusta, l'hosting remoto potrebbe essere su un altro fuso). Se il turno risultante e' lo
    // stesso dell'ultima riga si aggiorna quella; se e' cambiato (o non c'e' ancora nessuna riga)
    // se ne crea una nuova con freed_log vuoto.
    private void PushState(HttpContext context)
    {
        if (!RequirePost(context)) return;
        var body = ReadBody(context);

        // Validazione minima: deve essere JSON valido, altrimenti non sovrascrivere l'istantanea
        // buona con qualcosa di rotto.
        new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(body);
        var localNow = ParseLocalNow(context.Request.QueryString["now"]);
        var storedPayload = body;

        using (var connection = HubRiseIntegration.OpenDatabase())
        {
            var turno = ResolveCurrentTurno(connection, localNow);
            var latest = GetLatestSnapshotRow(connection);

            if (latest != null && turno != null && latest.TurnoTypeId == turno.TurnoTypeId && latest.TurnoStart == turno.TurnoStart)
            {
                using (var update = new MySqlCommand(
                    "UPDATE restaurant_state_snapshot SET state_payload = @payload, updated_at_utc = UTC_TIMESTAMP() WHERE id = @id",
                    connection))
                {
                    update.CommandTimeout = CommandTimeoutSeconds;
                    update.Parameters.AddWithValue("@payload", body);
                    update.Parameters.AddWithValue("@id", latest.Id);
                    update.ExecuteNonQuery();
                }
            }
            else
            {
                // Turno cambiato: il nuovo snapshot conserva la configurazione, ma non eredita
                // comande, pagamenti o storico del servizio precedente.
                storedPayload = latest == null ? body : ResetOperationalPayload(body);
                using (var insert = new MySqlCommand(@"
                    INSERT INTO restaurant_state_snapshot (turno_type_id, turno_start, state_payload, freed_log, updated_at_utc)
                    VALUES (@turnoTypeId, @turnoStart, @payload, '[]', UTC_TIMESTAMP())", connection))
                {
                    insert.CommandTimeout = CommandTimeoutSeconds;
                    insert.Parameters.AddWithValue("@turnoTypeId", turno != null ? (object)turno.TurnoTypeId : DBNull.Value);
                    insert.Parameters.AddWithValue("@turnoStart", turno != null ? (object)turno.TurnoStart : DBNull.Value);
                    insert.Parameters.AddWithValue("@payload", storedPayload);
                    insert.ExecuteNonQuery();
                }
            }
        }
        context.Response.Write("{\"ok\":true,\"state\":" + storedPayload + "}");
    }

    // POST ?mode=command - l'istanza esterna invia un'azione da mettere in coda.
    private void SubmitCommand(HttpContext context)
    {
        if (!RequirePost(context)) return;
        var body = ReadBody(context);

        Dictionary<string, object> command;
        try
        {
            command = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(body);
        }
        catch (Exception ex)
        {
            context.Response.StatusCode = 400;
            context.Response.Write("{\"error\":\"Body JSON non valido: " + ex.Message.Replace("\"", "'") + "\"}");
            return;
        }

        var clientCommandId = command != null && command.ContainsKey("client_command_id")
            ? Convert.ToString(command["client_command_id"]) : null;
        if (string.IsNullOrWhiteSpace(clientCommandId))
        {
            context.Response.StatusCode = 400;
            context.Response.Write("{\"error\":\"client_command_id obbligatorio\"}");
            return;
        }

        using (var connection = HubRiseIntegration.OpenDatabase())
        {
            using (var existing = new MySqlCommand(
                "SELECT COUNT(*) FROM restaurant_command_queue WHERE client_command_id = @clientCommandId", connection))
            {
                existing.CommandTimeout = CommandTimeoutSeconds;
                existing.Parameters.AddWithValue("@clientCommandId", clientCommandId);
                var alreadyExists = Convert.ToInt32(existing.ExecuteScalar()) > 0;
                if (alreadyExists)
                {
                    // Stesso comando rimandato (es. retry di rete): idempotente, non duplicare.
                    context.Response.Write("{\"ok\":true,\"duplicate\":true}");
                    return;
                }
            }
            using (var insert = new MySqlCommand(@"
                INSERT INTO restaurant_command_queue (client_command_id, command_json)
                VALUES (@clientCommandId, @commandJson)", connection))
            {
                insert.CommandTimeout = CommandTimeoutSeconds;
                insert.Parameters.AddWithValue("@clientCommandId", clientCommandId);
                insert.Parameters.AddWithValue("@commandJson", body);
                insert.ExecuteNonQuery();
            }
        }
        context.Response.Write("{\"ok\":true}");
    }

    // GET ?mode=pending_commands - il locale legge qui i comandi non ancora applicati.
    private void GetPendingCommands(HttpContext context)
    {
        var results = new List<object>();
        using (var connection = HubRiseIntegration.OpenDatabase())
        using (var command = new MySqlCommand(@"
            SELECT client_command_id, command_json
            FROM restaurant_command_queue
            WHERE applied_at_utc IS NULL
            ORDER BY id ASC
            LIMIT " + MaxPendingCommands, connection))
        {
            command.CommandTimeout = CommandTimeoutSeconds;
            using (var reader = command.ExecuteReader())
            {
                while (reader.Read())
                {
                    results.Add(new Dictionary<string, object>
                    {
                        { "client_command_id", reader["client_command_id"].ToString() },
                        { "command_json", reader["command_json"].ToString() }
                    });
                }
            }
        }
        context.Response.Write(new JavaScriptSerializer().Serialize(new Dictionary<string, object> { { "commands", results } }));
    }

    // POST ?mode=ack_commands - il locale conferma quali comandi ha applicato con successo.
    private void AckCommands(HttpContext context)
    {
        if (!RequirePost(context)) return;
        var body = ReadBody(context);

        Dictionary<string, object> request;
        try
        {
            request = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(body);
        }
        catch (Exception ex)
        {
            context.Response.StatusCode = 400;
            context.Response.Write("{\"error\":\"Body JSON non valido: " + ex.Message.Replace("\"", "'") + "\"}");
            return;
        }

        var ids = ExtractStringList(request, "client_command_ids");
        if (ids.Count == 0)
        {
            context.Response.Write("{\"ok\":true,\"acked\":0}");
            return;
        }

        using (var connection = HubRiseIntegration.OpenDatabase())
        using (var command = connection.CreateCommand())
        {
            command.CommandTimeout = CommandTimeoutSeconds;
            var placeholders = new List<string>();
            for (var i = 0; i < ids.Count; i++)
            {
                var paramName = "@id" + i;
                placeholders.Add(paramName);
                command.Parameters.AddWithValue(paramName, ids[i]);
            }
            command.CommandText = "UPDATE restaurant_command_queue SET applied_at_utc = UTC_TIMESTAMP() WHERE client_command_id IN (" +
                string.Join(",", placeholders) + ") AND applied_at_utc IS NULL";
            var affected = command.ExecuteNonQuery();
            context.Response.Write("{\"ok\":true,\"acked\":" + affected + "}");
        }
    }

    // GET ?mode=command_status&ids=cmd-1,cmd-2 - l'esterno controlla se i suoi comandi sono stati
    // gia' applicati dal locale (per la striscia di stato "confermato/in attesa").
    private void GetCommandStatus(HttpContext context)
    {
        var idsParam = context.Request.QueryString["ids"] ?? "";
        var ids = new List<string>();
        foreach (var raw in idsParam.Split(','))
        {
            var trimmed = raw.Trim();
            if (trimmed.Length > 0) ids.Add(trimmed);
        }

        var result = new Dictionary<string, object>();
        if (ids.Count == 0)
        {
            context.Response.Write(new JavaScriptSerializer().Serialize(new Dictionary<string, object> { { "statuses", result } }));
            return;
        }

        using (var connection = HubRiseIntegration.OpenDatabase())
        using (var command = connection.CreateCommand())
        {
            command.CommandTimeout = CommandTimeoutSeconds;
            var placeholders = new List<string>();
            for (var i = 0; i < ids.Count; i++)
            {
                var paramName = "@id" + i;
                placeholders.Add(paramName);
                command.Parameters.AddWithValue(paramName, ids[i]);
            }
            command.CommandText = "SELECT client_command_id, applied_at_utc FROM restaurant_command_queue WHERE client_command_id IN (" +
                string.Join(",", placeholders) + ")";
            using (var reader = command.ExecuteReader())
            {
                while (reader.Read())
                {
                    var appliedAt = reader["applied_at_utc"] == DBNull.Value
                        ? null
                        : Convert.ToDateTime(reader["applied_at_utc"]).ToString("o");
                    result[reader["client_command_id"].ToString()] = appliedAt;
                }
            }
        }
        context.Response.Write(new JavaScriptSerializer().Serialize(new Dictionary<string, object> { { "statuses", result } }));
    }

    // POST ?mode=log_freed - il locale registra qui, in modo permanente, un tavolo o un
    // Pick-up "liberato" (bottone "Libera tavolo"): a differenza dell'istantanea di stato,
    // che viene sovrascritta ad ogni push, questa e' una tabella append-only pensata per un
    // controllo/audit da remoto, non per il rendering della pagina.
    private void LogFreed(HttpContext context)
    {
        if (!RequirePost(context)) return;
        var body = ReadBody(context);

        Dictionary<string, object> request;
        try
        {
            request = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(body);
        }
        catch (Exception ex)
        {
            context.Response.StatusCode = 400;
            context.Response.Write("{\"error\":\"Body JSON non valido: " + ex.Message.Replace("\"", "'") + "\"}");
            return;
        }

        var entityType = request != null && request.ContainsKey("entity_type") ? Convert.ToString(request["entity_type"]) : null;
        var entityId = request != null && request.ContainsKey("entity_id") ? Convert.ToString(request["entity_id"]) : null;
        if (string.IsNullOrWhiteSpace(entityType) || string.IsNullOrWhiteSpace(entityId))
        {
            context.Response.StatusCode = 400;
            context.Response.Write("{\"error\":\"entity_type ed entity_id obbligatori\"}");
            return;
        }
        var label = request != null && request.ContainsKey("label") ? Convert.ToString(request["label"]) : null;
        object payloadValue = request != null && request.ContainsKey("payload") ? request["payload"] : null;
        var payloadJson = payloadValue != null ? new JavaScriptSerializer().Serialize(payloadValue) : "{}";
        var payloadObject = payloadValue as Dictionary<string, object>;
        if (payloadObject != null)
        {
            payloadObject["history_entity_type"] = entityType;
            payloadValue = payloadObject;
            payloadJson = new JavaScriptSerializer().Serialize(payloadValue);
        }
        var localNow = ParseLocalNow(context.Request.QueryString["now"]);
        var freedAtUtc = DateTime.UtcNow;

        using (var connection = HubRiseIntegration.OpenDatabase())
        {
            using (var historyCommand = new MySqlCommand(@"
                    INSERT INTO restaurant_table_history
                        (payload_json)
                    VALUES
                        (JSON_SET(@payloadJson,
                            '$.history_id', UUID(),
                            '$._closed_at_utc', UTC_TIMESTAMP()))", connection))
            {
                historyCommand.CommandTimeout = CommandTimeoutSeconds;
                historyCommand.Parameters.AddWithValue("@payloadJson", payloadJson);
                historyCommand.ExecuteNonQuery();
            }
            using (var command = new MySqlCommand(@"
                INSERT INTO restaurant_freed_log (entity_type, entity_id, label, payload_json)
                VALUES (@entityType, @entityId, @label, @payloadJson)", connection))
            {
                command.CommandTimeout = CommandTimeoutSeconds;
                command.Parameters.AddWithValue("@entityType", entityType);
                command.Parameters.AddWithValue("@entityId", entityId);
                command.Parameters.AddWithValue("@label", (object)label ?? DBNull.Value);
                command.Parameters.AddWithValue("@payloadJson", (object)payloadJson ?? DBNull.Value);
                command.ExecuteNonQuery();
            }

            // In piu' della riga permanente sopra (che resta per sempre, per l'audit), si appende
            // lo stesso evento all'array freed_log della riga del turno corrente: cosi' "cosa si
            // e' liberato in questo turno" si legge subito con mode=state, senza un'altra query SQL.
            var record = new Dictionary<string, object>
            {
                { "entity_type", entityType },
                { "entity_id", entityId },
                { "label", label },
                { "payload", payloadValue },
                { "freed_at_utc", freedAtUtc.ToString("o") }
            };
            var recordJson = new JavaScriptSerializer().Serialize(record);

            var turno = ResolveCurrentTurno(connection, localNow);
            var latest = GetLatestSnapshotRow(connection);

            if (latest != null && turno != null && latest.TurnoTypeId == turno.TurnoTypeId && latest.TurnoStart == turno.TurnoStart)
            {
                var list = new List<object>();
                if (!string.IsNullOrEmpty(latest.FreedLogJson))
                {
                    try { list = new JavaScriptSerializer().Deserialize<List<object>>(latest.FreedLogJson) ?? new List<object>(); }
                    catch { list = new List<object>(); }
                }
                list.Add(new JavaScriptSerializer().Deserialize<object>(recordJson));
                var freedLogJson = new JavaScriptSerializer().Serialize(list);
                using (var update = new MySqlCommand(
                    "UPDATE restaurant_state_snapshot SET freed_log = @freedLog WHERE id = @id",
                    connection))
                {
                    update.CommandTimeout = CommandTimeoutSeconds;
                    update.Parameters.AddWithValue("@freedLog", freedLogJson);
                    update.Parameters.AddWithValue("@id", latest.Id);
                    update.ExecuteNonQuery();
                }
            }
            else
            {
                // Turno cambiato (o "Libera tavolo" e' il primissimo evento in assoluto, prima
                // ancora che push_state abbia mai scritto una riga): si crea la riga del nuovo
                // turno gia' con questo record dentro, portando avanti l'ultima istantanea nota
                // (se c'e') cosi' lo stato non appare vuoto finche' non arriva il prossimo push.
                var freedLogJson = new JavaScriptSerializer().Serialize(new List<object> { new JavaScriptSerializer().Deserialize<object>(recordJson) });
                using (var insert = new MySqlCommand(@"
                    INSERT INTO restaurant_state_snapshot (turno_type_id, turno_start, state_payload, freed_log, updated_at_utc)
                    VALUES (@turnoTypeId, @turnoStart, @payload, @freedLog, UTC_TIMESTAMP())", connection))
                {
                    insert.CommandTimeout = CommandTimeoutSeconds;
                    insert.Parameters.AddWithValue("@turnoTypeId", turno != null ? (object)turno.TurnoTypeId : DBNull.Value);
                    insert.Parameters.AddWithValue("@turnoStart", turno != null ? (object)turno.TurnoStart : DBNull.Value);
                    insert.Parameters.AddWithValue("@payload", latest != null && !string.IsNullOrEmpty(latest.StatePayload) ? latest.StatePayload : "{}");
                    insert.Parameters.AddWithValue("@freedLog", freedLogJson);
                    insert.ExecuteNonQuery();
                }
            }
        }
        context.Response.Write("{\"ok\":true}");
    }

    // "yyyy-MM-ddTHH:mm:ss" (ora locale del ristorante, mandata da server.js) o, se mancante/non
    // valida, l'ora del server remoto come ripiego (meno affidabile, ma meglio di niente).
    private static DateTime ParseLocalNow(string raw)
    {
        DateTime parsed;
        if (!string.IsNullOrWhiteSpace(raw) &&
            DateTime.TryParseExact(raw.Trim(), "yyyy-MM-ddTHH:mm:ss", CultureInfo.InvariantCulture, DateTimeStyles.None, out parsed))
        {
            return parsed;
        }
        return DateTime.Now;
    }

    private static string ResetOperationalPayload(string body)
    {
        var serializer = new JavaScriptSerializer();
        var state = serializer.Deserialize<Dictionary<string, object>>(body);
        var tables = state.ContainsKey("tables") ? state["tables"] as object[] : null;
        if (tables != null)
        {
            foreach (var item in tables)
            {
                var table = item as Dictionary<string, object>;
                if (table == null) continue;
                table["occupied"] = false;
                table["covers"] = 0;
                table["notes"] = "";
                table["status"] = "Nuova";
                table["splitMode"] = false;
                table["selectedSplit"] = "T";
                table["splitCovers"] = new Dictionary<string, object>();
                table["splitLabels"] = new Dictionary<string, object>();
                table["paidSplits"] = new Dictionary<string, object>();
                table["selectedCourse"] = 1;
                table["activeCourse"] = 1;
                table["courseSequence"] = new object[] { 1 };
                table["lines"] = new object[0];
            }
        }
        state["history"] = new object[0];
        state["deliveryOrders"] = new object[0];
        state["courseActivationOrder"] = new object[0];
        state["selectedTable"] = null;
        return serializer.Serialize(state);
    }

    private class TurnoInfo
    {
        public int TurnoTypeId;
        public DateTime TurnoStart;
    }

    // Determina a quale turno appartiene "localNow", secondo i tipi di turno attivi (restaurant_
    // turno_types). Gestisce le finestre che attraversano la mezzanotte (es. 18->3): se nessun tipo
    // copre l'ora corrente (es. ore chiuse, tra un turno e l'altro), si assegna al prossimo turno
    // che comincia oggi, o - se anche quello e' gia' passato - al primo tipo attivo.
    private static TurnoInfo ResolveCurrentTurno(MySqlConnection connection, DateTime localNow)
    {
        var types = new List<Tuple<int, int, int>>(); // id, start_hour, end_hour
        using (var select = new MySqlCommand(
            "SELECT id, start_hour, end_hour FROM restaurant_turno_types WHERE is_active = 1 ORDER BY start_hour", connection))
        {
            select.CommandTimeout = CommandTimeoutSeconds;
            using (var reader = select.ExecuteReader())
            {
                while (reader.Read())
                {
                    types.Add(Tuple.Create(Convert.ToInt32(reader["id"]), Convert.ToInt32(reader["start_hour"]), Convert.ToInt32(reader["end_hour"])));
                }
            }
        }
        if (types.Count == 0) return null;

        var hour = localNow.Hour;
        var today = localNow.Date;

        foreach (var type in types)
        {
            var startHour = type.Item2;
            var endHour = type.Item3;
            var contains = startHour < endHour
                ? (hour >= startHour && hour < endHour)
                : (hour >= startHour || hour < endHour);
            if (!contains) continue;
            var turnoStart = hour >= startHour ? today.AddHours(startHour) : today.AddDays(-1).AddHours(startHour);
            return new TurnoInfo { TurnoTypeId = type.Item1, TurnoStart = turnoStart };
        }

        var upcoming = types.Where(type => type.Item2 > hour).OrderBy(type => type.Item2).FirstOrDefault();
        var chosen = upcoming ?? types.OrderBy(type => type.Item2).First();
        return new TurnoInfo { TurnoTypeId = chosen.Item1, TurnoStart = today.AddHours(chosen.Item2) };
    }

    private class SnapshotRow
    {
        public long Id;
        public int? TurnoTypeId;
        public DateTime? TurnoStart;
        public string StatePayload;
        public string FreedLogJson;
    }

    private static SnapshotRow GetLatestSnapshotRow(MySqlConnection connection)
    {
        using (var select = new MySqlCommand(
            "SELECT id, turno_type_id, turno_start, state_payload, freed_log FROM restaurant_state_snapshot ORDER BY id DESC LIMIT 1", connection))
        {
            select.CommandTimeout = CommandTimeoutSeconds;
            using (var reader = select.ExecuteReader())
            {
                if (!reader.Read()) return null;
                return new SnapshotRow
                {
                    Id = Convert.ToInt64(reader["id"]),
                    TurnoTypeId = reader["turno_type_id"] == DBNull.Value ? (int?)null : Convert.ToInt32(reader["turno_type_id"]),
                    TurnoStart = reader["turno_start"] == DBNull.Value ? (DateTime?)null : Convert.ToDateTime(reader["turno_start"]),
                    StatePayload = reader["state_payload"] == DBNull.Value ? null : reader["state_payload"].ToString(),
                    FreedLogJson = reader["freed_log"] == DBNull.Value ? null : reader["freed_log"].ToString()
                };
            }
        }
    }

    private bool RequirePost(HttpContext context)
    {
        if (string.Equals(context.Request.HttpMethod, "POST", StringComparison.OrdinalIgnoreCase)) return true;
        context.Response.StatusCode = 405;
        context.Response.Write("{\"error\":\"POST required\"}");
        return false;
    }

    private string ReadBody(HttpContext context)
    {
        using (var reader = new StreamReader(context.Request.InputStream, Encoding.UTF8)) return reader.ReadToEnd();
    }

    private static List<string> ExtractStringList(Dictionary<string, object> node, string key)
    {
        var result = new List<string>();
        object value;
        if (node == null || !node.TryGetValue(key, out value) || value == null) return result;
        var enumerable = value as System.Collections.IEnumerable;
        if (enumerable == null) return result;
        foreach (var item in enumerable)
        {
            var text = Convert.ToString(item);
            if (!string.IsNullOrWhiteSpace(text)) result.Add(text);
        }
        return result;
    }
}
