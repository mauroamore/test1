<%@ WebService Language="C#" Class="RestaurantOperationsService" %>

using System;
using System.Collections.Generic;
using System.Web.Script.Serialization;
using System.Web.Script.Services;
using System.Web.Services;
using MySql.Data.MySqlClient;

[ScriptService]
[WebService(Namespace = "http://thaiprincess.it/restaurant-operations/")]
[WebServiceBinding(ConformsTo = WsiProfiles.BasicProfile1_1)]
public class RestaurantOperationsService : WebService
{
    private const int TimeoutSeconds = 15;
    private readonly JavaScriptSerializer serializer = new JavaScriptSerializer();

    [WebMethod]
    [ScriptMethod(ResponseFormat = ResponseFormat.Json)]
    public string GetState()
    {
        RequireKey();
        using (var connection = HubRiseIntegration.OpenDatabase())
        using (var command = new MySqlCommand("SELECT state_payload, updated_at_utc FROM restaurant_state_snapshot ORDER BY id DESC LIMIT 1", connection))
        {
            command.CommandTimeout = TimeoutSeconds;
            using (var reader = command.ExecuteReader())
            {
                if (!reader.Read()) return "{\"ok\":true,\"has_state\":false,\"tables\":[]}";
                var raw = reader["state_payload"] == DBNull.Value ? "{}" : reader["state_payload"].ToString();
                var parsed = new JavaScriptSerializer { MaxJsonLength = Int32.MaxValue }.DeserializeObject(raw) as Dictionary<string, object>;
                var tables = new List<object>();
                var rawTables = parsed == null ? null : parsed["tables"] as object[];
                if (rawTables != null) foreach (var value in rawTables)
                {
                    var table = value as Dictionary<string, object>;
                    if (table == null) continue;
                    var items = table.ContainsKey("items") ? table["items"] as object[] : null;
                    var tho = table.ContainsKey("tho") ? table["tho"] : null;
                    tables.Add(new Dictionary<string, object>
                    {
                        { "id", table.ContainsKey("id") ? table["id"] : null },
                        { "occupied", table.ContainsKey("occupied") && Convert.ToBoolean(table["occupied"]) },
                        { "covers", table.ContainsKey("covers") ? table["covers"] : 0 },
                        { "items_count", items == null ? 0 : items.Length },
                        { "tho", tho }
                    });
                }
                return serializer.Serialize(new Dictionary<string, object>
                {
                    { "ok", true },
                    { "has_state", true },
                    { "updated_at_utc", reader["updated_at_utc"] == DBNull.Value ? null : Convert.ToDateTime(reader["updated_at_utc"]).ToString("o") },
                    { "tables", tables }
                });
            }
        }
    }

    [WebMethod]
    [ScriptMethod(ResponseFormat = ResponseFormat.Json)]
    public string OpenTable(string payload) { RequireKey(); return Queue("open_table", payload); }

    [WebMethod]
    [ScriptMethod(ResponseFormat = ResponseFormat.Json)]
    public string AdoptWalkIn(string payload) { RequireKey(); return Queue("adopt_walkin", payload); }

    [WebMethod]
    [ScriptMethod(ResponseFormat = ResponseFormat.Json)]
    public string MoveReservation(string payload) { RequireKey(); return Queue("move_reservation", payload); }

    [WebMethod]
    [ScriptMethod(ResponseFormat = ResponseFormat.Json)]
    public string ClearReservation(string payload) { RequireKey(); return Queue("clear_reservation", payload); }

    [WebMethod]
    [ScriptMethod(ResponseFormat = ResponseFormat.Json)]
    public string GetCommandStatus(string commandId)
    {
        RequireKey();
        var statuses = new Dictionary<string, object>();
        if (String.IsNullOrWhiteSpace(commandId)) return serializer.Serialize(new Dictionary<string, object> { { "statuses", statuses } });
        using (var connection = HubRiseIntegration.OpenDatabase())
        using (var command = new MySqlCommand("SELECT applied_at_utc FROM restaurant_command_queue WHERE client_command_id = @id LIMIT 1", connection))
        {
            command.CommandTimeout = TimeoutSeconds;
            command.Parameters.AddWithValue("@id", commandId);
            var applied = command.ExecuteScalar();
            statuses[commandId] = applied == null || applied == DBNull.Value ? null : Convert.ToDateTime(applied).ToString("o");
        }
        return serializer.Serialize(new Dictionary<string, object> { { "statuses", statuses } });
    }

    [WebMethod]
    [ScriptMethod(ResponseFormat = ResponseFormat.Json)]
    public string SaveFiscalReceipt(string data)
    {
        RequireKey();
        try
        {
            if (String.IsNullOrWhiteSpace(data))
                return serializer.Serialize(new { ok = false, error = "The fiscal receipt data is required." });

            var payload = new JavaScriptSerializer { MaxJsonLength = Int32.MaxValue }
                .Deserialize<Dictionary<string, object>>(data);
            if (payload == null || !payload.ContainsKey("id") || payload["id"] == null)
                return serializer.Serialize(new { ok = false, error = "The fiscal receipt JSON must contain id." });

            using (var connection = HubRiseIntegration.OpenDatabase())
            using (var command = new MySqlCommand(@"
                INSERT INTO fiscal_receipts (data)
                VALUES (CAST(@data AS JSON))
                ON DUPLICATE KEY UPDATE data = VALUES(data)", connection))
            {
                command.CommandTimeout = TimeoutSeconds;
                command.Parameters.Add("@data", MySqlDbType.LongText).Value = data;
                command.ExecuteNonQuery();
            }
            return serializer.Serialize(new { ok = true, id = Convert.ToString(payload["id"]) });
        }
        catch (Exception ex)
        {
            return serializer.Serialize(new { ok = false, error = ex.Message });
        }
    }

    [WebMethod]
    [ScriptMethod(ResponseFormat = ResponseFormat.Json)]
    public string GetFiscalReceipts(string year, string from = null, string to = null)
    {
        RequireKey();
        var result = new List<object>();
        var readerSerializer = new JavaScriptSerializer { MaxJsonLength = Int32.MaxValue };
        try
        {
            using (var connection = HubRiseIntegration.OpenDatabase())
            using (var command = new MySqlCommand(@"
                SELECT CAST(data AS CHAR) AS data, id, restaurant_id, order_id, table_id,
                       source, document_number, receipt_number, fiscal_receipt_date,
                       fiscal_receipt_time, rt_serial_number, amount, payment_method,
                       status, emitted_at, voided_at, void_reason, reissue_of
                FROM fiscal_receipts
                WHERE emitted_at >= CONCAT(@year, '-01-01T00:00:00')
                  AND emitted_at < CONCAT(CAST(@year AS UNSIGNED) + 1, '-01-01T00:00:00')
                  AND (@from = '' OR emitted_at >= @from)
                  AND (@to = '' OR emitted_at <= @to)
                ORDER BY emitted_at DESC, id DESC
                LIMIT 10000", connection))
            {
                command.CommandTimeout = TimeoutSeconds;
                command.Parameters.Add("@year", MySqlDbType.VarChar, 4).Value = year ?? "";
                command.Parameters.Add("@from", MySqlDbType.VarChar, 30).Value = from ?? "";
                command.Parameters.Add("@to", MySqlDbType.VarChar, 30).Value = to ?? "";
                using (var reader = command.ExecuteReader())
                {
                    while (reader.Read())
                    {
                        var item = new Dictionary<string, object>();
                        for (var i = 0; i < reader.FieldCount; i++)
                            item[reader.GetName(i)] = reader.IsDBNull(i) ? null : reader.GetValue(i);
                        var rawData = Convert.ToString(item["data"] ?? "{}");
                        try { item["data"] = readerSerializer.DeserializeObject(rawData); }
                        catch { }
                        result.Add(item);
                    }
                }
            }
            return readerSerializer.Serialize(new { ok = true, receipts = result });
        }
        catch (Exception ex)
        {
            return readerSerializer.Serialize(new { ok = false, error = ex.Message, receipts = result });
        }
    }

    private string Queue(string operation, string payload)
    {
        var commandId = operation + "-" + Guid.NewGuid().ToString("N");
        var command = new Dictionary<string, object> { { "client_command_id", commandId }, { "type", operation } };
        var payloadObject = String.IsNullOrWhiteSpace(payload) ? null : serializer.DeserializeObject(payload) as Dictionary<string, object>;
        if (payloadObject != null) foreach (var item in payloadObject) command[item.Key] = item.Value;
        var body = serializer.Serialize(command);
        using (var connection = HubRiseIntegration.OpenDatabase())
        using (var insert = new MySqlCommand("INSERT INTO restaurant_command_queue (client_command_id, command_json) VALUES (@id, @json)", connection))
        {
            insert.CommandTimeout = TimeoutSeconds;
            insert.Parameters.AddWithValue("@id", commandId);
            insert.Parameters.AddWithValue("@json", body);
            insert.ExecuteNonQuery();
        }
        return serializer.Serialize(new Dictionary<string, object> { { "ok", true }, { "command_id", commandId }, { "status", "queued" } });
    }

    private void RequireKey()
    {
        var expected = System.Configuration.ConfigurationManager.AppSettings["RestaurantSyncKey"];
        var supplied = Context.Request.Headers["X-Restaurant-Operations-Key"] ?? Context.Request.QueryString["key"];
        if (String.IsNullOrWhiteSpace(expected) || !String.Equals(expected, supplied, StringComparison.Ordinal)) throw new UnauthorizedAccessException("Unauthorized");
    }
}
