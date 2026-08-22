<%@ WebService Language="C#" Class="DeliverooService" %>

using System;
using System.Collections.Generic;
using System.Web.Services;
using System.Web.Script.Services;
using MySql.Data.MySqlClient;
using System.Configuration;

[WebService(Namespace = "http://thaiprincess.it/deliveroo/")]
[ScriptService]
public class DeliverooService : WebService
{
    [WebMethod]
    [ScriptMethod(ResponseFormat = ResponseFormat.Json)]
    public object GetOrders()
    {
        var result = new List<object>();
        var cs = ConfigurationManager.ConnectionStrings["MySqlConnectionString"].ConnectionString;
        using (var connection = new MySqlConnection(cs))
        using (var command = new MySqlCommand(@"
            SELECT external_order_id, order_number, display_id, status,
                   total_fractional, currency_code, last_received_at_utc
            FROM deliveroo_order
            ORDER BY last_received_at_utc DESC
            LIMIT 100", connection))
        {
            using (var reader = command.ExecuteReader())
            {
                while (reader.Read())
                {
                    result.Add(new {
                        id = reader["external_order_id"].ToString(),
                        number = reader["order_number"].ToString(),
                        display = reader["display_id"].ToString(),
                        status = reader["status"].ToString(),
                        total = Convert.ToInt64(reader["total_fractional"]) / 100.0,
                        currency = reader["currency_code"].ToString(),
                        received = Convert.ToDateTime(reader["last_received_at_utc"]).ToString("yyyy-MM-dd HH:mm:ss")
                    });
                }
            }
        }
        return result;
    }

    [WebMethod]
    [ScriptMethod(ResponseFormat = ResponseFormat.Json)]
    public object GetWebhookLogs()
    {
        var result = new List<object>();
        var cs = ConfigurationManager.ConnectionStrings["MySqlConnectionString"].ConnectionString;
        using (var connection = new MySqlConnection(cs))
        using (var command = new MySqlCommand(@"
            SELECT id, received_at_utc, request_path, processed, payload
            FROM deliveroo_webhook_log
            ORDER BY id DESC
            LIMIT 50", connection))
        {
            using (var reader = command.ExecuteReader())
            {
                while (reader.Read())
                {
                    result.Add(new {
                        id = Convert.ToInt64(reader["id"]),
                        received = Convert.ToDateTime(reader["received_at_utc"]).ToString("yyyy-MM-dd HH:mm:ss"),
                        path = reader["request_path"].ToString(),
                        processed = Convert.ToInt32(reader["processed"]) == 1,
                        payload = reader["payload"].ToString()
                    });
                }
            }
        }
        return result;
    }
}
