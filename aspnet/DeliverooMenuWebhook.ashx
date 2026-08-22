<%@ WebHandler Language="C#" Class="DeliverooMenuWebhook" %>

using System;
using System.IO;
using System.Text;
using System.Web;
using System.Configuration;
using MySql.Data.MySqlClient;

public class DeliverooMenuWebhook : IHttpHandler
{
    public bool IsReusable { get { return false; } }

    public void ProcessRequest(HttpContext context)
    {
        context.Response.ContentType = "application/json; charset=utf-8";
        context.Response.StatusCode = 200;

        // Read and persist the callback before acknowledging it. Deliveroo retries
        // callbacks that time out or receive a non-2xx response.
        string payload;
        using (var reader = new StreamReader(context.Request.InputStream, Encoding.UTF8))
        {
            payload = reader.ReadToEnd();
        }

        context.Cache["last_deliveroo_menu_callback"] = payload;
        LogWebhook(payload, context);

        context.Response.Write("{}");
    }

    private void LogWebhook(string payload, HttpContext context)
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

            var connectionString = ConfigurationManager.ConnectionStrings["MySqlConnectionString"].ConnectionString;
            using (var connection = new MySqlConnection(connectionString))
            using (var command = new MySqlCommand(@"
                INSERT INTO deliveroo_webhook_log
                    (received_at_utc, request_path, request_headers, payload, processed)
                VALUES
                    (UTC_TIMESTAMP(), @path, @headers, @payload, 0)", connection))
            {
                connection.Open();
                command.CommandTimeout = 5;
                command.Parameters.AddWithValue("@path", context.Request.Path);
                command.Parameters.AddWithValue("@headers", headers.ToString());
                command.Parameters.AddWithValue("@payload", payload);
                command.ExecuteNonQuery();
            }
        }
        catch
        {
            // Never return a non-2xx response to Deliveroo because logging failed.
        }
    }
}
