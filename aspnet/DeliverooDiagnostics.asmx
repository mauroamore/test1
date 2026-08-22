<%@ WebService Language="C#" Class="DeliverooDiagnostics" %>

using System;
using System.Collections.Generic;
using System.Configuration;
using System.Web.Services;
using System.Web.Script.Serialization;
using MySql.Data.MySqlClient;

[WebService(Namespace = "http://thaiprincess.it/deliveroo/")]
public class DeliverooDiagnostics : WebService
{
    [WebMethod]
    public string GetSummary(string key)
    {
        var expected = ConfigurationManager.AppSettings["DeliverooDiagnosticsKey"];
        if (string.IsNullOrEmpty(expected) || !string.Equals(key, expected, StringComparison.Ordinal))
            throw new UnauthorizedAccessException("Invalid diagnostics key");

        var result = new Dictionary<string, object>();
        var cs = ConfigurationManager.ConnectionStrings["MySqlConnectionString"].ConnectionString;
        using (var connection = new MySqlConnection(cs))
        {
            connection.Open();
            result["database"] = "connected";
            result["orders"] = Scalar(connection, "SELECT COUNT(*) FROM deliveroo_order");
            result["webhooks"] = Scalar(connection, "SELECT COUNT(*) FROM deliveroo_webhook_log");
            result["recent_orders"] = RecentOrders(connection);
            result["recent_webhooks"] = RecentWebhooks(connection);
            result["recent_errors"] = RecentErrors(connection);
            result["last_webhook_payload"] = LastWebhookPayload(connection);
        }
        return new JavaScriptSerializer().Serialize(result);
    }

    private object Scalar(MySqlConnection connection, string sql)
    {
        using (var command = new MySqlCommand(sql, connection)) return command.ExecuteScalar();
    }

    private List<object> RecentOrders(MySqlConnection connection)
    {
        var result = new List<object>();
        using (var command = new MySqlCommand(@"SELECT external_order_id, display_id, status,
            total_fractional, currency_code, last_received_at_utc
            FROM deliveroo_order ORDER BY id DESC LIMIT 10", connection))
        using (var reader = command.ExecuteReader())
        {
            while (reader.Read()) result.Add(new {
                id = reader["external_order_id"].ToString(),
                display = reader["display_id"].ToString(),
                status = reader["status"].ToString(),
                total = Convert.ToInt64(reader["total_fractional"]),
                currency = reader["currency_code"].ToString(),
                received = Convert.ToDateTime(reader["last_received_at_utc"]).ToString("o")
            });
        }
        return result;
    }

    private List<object> RecentWebhooks(MySqlConnection connection)
    {
        var result = new List<object>();
        using (var command = new MySqlCommand(@"SELECT id, received_at_utc, request_path,
            processed FROM deliveroo_webhook_log ORDER BY id DESC LIMIT 10", connection))
        using (var reader = command.ExecuteReader())
        {
            while (reader.Read()) result.Add(new {
                id = Convert.ToInt64(reader["id"]),
                received = Convert.ToDateTime(reader["received_at_utc"]).ToString("o"),
                path = reader["request_path"].ToString(),
                processed = Convert.ToInt32(reader["processed"]) == 1
            });
        }
        return result;
    }

    private List<object> RecentErrors(MySqlConnection connection)
    {
        var result = new List<object>();
        using (var command = new MySqlCommand(@"SELECT id, created_at_utc, message
            FROM deliveroo_process_log
            ORDER BY id DESC LIMIT 10", connection))
        using (var reader = command.ExecuteReader())
        {
            while (reader.Read()) result.Add(new {
                id = Convert.ToInt64(reader["id"]),
                received = Convert.ToDateTime(reader["created_at_utc"]).ToString("o"),
                error = reader["message"].ToString()
            });
        }
        return result;
    }

    private string LastWebhookPayload(MySqlConnection connection)
    {
        using (var command = new MySqlCommand(@"SELECT CAST(payload AS CHAR) AS payload_text
            FROM deliveroo_webhook_log
            WHERE request_path LIKE '%DeliverooWebhook%'
            ORDER BY id DESC LIMIT 1", connection))
        {
            var value = command.ExecuteScalar();
            return value == null || value == DBNull.Value ? "" : Convert.ToString(value);
        }
    }
}
