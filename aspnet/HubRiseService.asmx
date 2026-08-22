<%@ WebService Language="C#" Class="HubRiseService" %>

using System;
using System.Collections.Generic;
using System.Configuration;
using System.Web.Services;
using System.Web.Script.Services;
using MySql.Data.MySqlClient;

/// <summary>
/// Read-only service for the external HubRise monitor page (HubRiseMonitor.html). Independent
/// from DeliverooService.asmx; unlike that service, every method here requires a shared key so
/// order/customer data is not exposed on a public, unauthenticated endpoint.
/// </summary>
[WebService(Namespace = "http://thaiprincess.it/hubrise/")]
[ScriptService]
public class HubRiseService : WebService
{
    [WebMethod]
    [ScriptMethod(ResponseFormat = ResponseFormat.Json)]
    public object GetOrders(string key)
    {
        RequireKey(key);
        var result = new List<object>();
        using (var connection = OpenDatabase())
        using (var command = new MySqlCommand(@"
            SELECT external_order_id, status, service_type, customer_name,
                   total_fractional, currency_code, last_received_at_utc
            FROM hubrise_order
            ORDER BY last_received_at_utc DESC
            LIMIT 100", connection))
        {
            using (var reader = command.ExecuteReader())
            {
                while (reader.Read())
                {
                    result.Add(new
                    {
                        id = reader["external_order_id"].ToString(),
                        status = reader["status"] as string,
                        serviceType = reader["service_type"] as string,
                        customer = reader["customer_name"] as string,
                        total = reader["total_fractional"] == DBNull.Value ? (double?)null : Convert.ToInt64(reader["total_fractional"]) / 100.0,
                        currency = reader["currency_code"] as string,
                        received = Convert.ToDateTime(reader["last_received_at_utc"]).ToString("yyyy-MM-dd HH:mm:ss")
                    });
                }
            }
        }
        return result;
    }

    [WebMethod]
    [ScriptMethod(ResponseFormat = ResponseFormat.Json)]
    public object GetWebhookLogs(string key)
    {
        RequireKey(key);
        var result = new List<object>();
        using (var connection = OpenDatabase())
        using (var command = new MySqlCommand(@"
            SELECT id, received_at_utc, request_path, processed, payload
            FROM hubrise_webhook_log
            ORDER BY id DESC
            LIMIT 50", connection))
        {
            using (var reader = command.ExecuteReader())
            {
                while (reader.Read())
                {
                    result.Add(new
                    {
                        id = Convert.ToInt64(reader["id"]),
                        received = Convert.ToDateTime(reader["received_at_utc"]).ToString("yyyy-MM-dd HH:mm:ss"),
                        path = reader["request_path"] as string,
                        processed = Convert.ToInt32(reader["processed"]) == 1,
                        payload = reader["payload"].ToString()
                    });
                }
            }
        }
        return result;
    }

    private static void RequireKey(string suppliedKey)
    {
        var expectedKey = ConfigurationManager.AppSettings["HubRiseMonitorKey"];
        if (string.IsNullOrEmpty(expectedKey) || !string.Equals(expectedKey, suppliedKey, StringComparison.Ordinal))
            throw new InvalidOperationException("Unauthorized");
    }

    private static MySqlConnection OpenDatabase()
    {
        var builder = new MySqlConnectionStringBuilder(
            ConfigurationManager.ConnectionStrings["MySqlConnectionString"].ConnectionString);
        // Chiamata rara e sporadica (pagina di monitor aperta a mano): niente pooling,
        // cosi' non si rischia di riusare una connessione gia' chiusa dal server per inattivita'.
        builder.Pooling = false;
        var connection = new MySqlConnection(builder.ConnectionString);
        connection.Open();
        return connection;
    }
}
