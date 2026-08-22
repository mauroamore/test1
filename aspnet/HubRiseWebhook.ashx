<%@ WebHandler Language="C#" Class="HubRiseWebhook" %>

using System;
using System.Collections.Generic;
using System.Configuration;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Web;
using System.Web.Script.Serialization;
using MySql.Data.MySqlClient;

/// <summary>
/// Inbound order webhook for HubRise. Independent from DeliverooWebhook.ashx by design, but
/// mirrors its sound parts: log the raw payload before anything else, always ack fast (HTTP 200),
/// and process/save asynchronously with retry so a slow or failing DB write never blocks the ack.
/// HubRise signs callbacks with header X-HubRise-Hmac-SHA256 (HMAC-SHA256 of the raw body, keyed
/// with the OAuth client secret) - verified here in addition to the shared secret embedded in the
/// registered callback URL query string (?wh=...).
/// </summary>
public class HubRiseWebhook : IHttpHandler
{
    private const int CommandTimeoutSeconds = 25;

    public bool IsReusable { get { return false; } }

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

        var expectedSecret = ConfigurationManager.AppSettings["HubRiseWebhookSecret"];
        var suppliedSecret = context.Request.QueryString["wh"];
        if (string.IsNullOrEmpty(expectedSecret) || !string.Equals(expectedSecret, suppliedSecret, StringComparison.Ordinal))
        {
            context.Response.StatusCode = 401;
            context.Response.ContentType = "application/json";
            context.Response.Write("{\"error\":\"Unauthorized\"}");
            return;
        }

        byte[] rawBody;
        using (var buffer = new MemoryStream())
        {
            context.Request.InputStream.CopyTo(buffer);
            rawBody = buffer.ToArray();
        }
        var body = Encoding.UTF8.GetString(rawBody);

        var clientSecret = ConfigurationManager.AppSettings["HubRiseClientSecret"];
        if (!string.IsNullOrEmpty(clientSecret))
        {
            var suppliedHmac = context.Request.Headers["X-HubRise-Hmac-SHA256"];
            byte[] digest;
            using (var hmac = new HMACSHA256(Encoding.UTF8.GetBytes(clientSecret)))
            {
                digest = hmac.ComputeHash(rawBody);
            }
            var expectedHmac = BitConverter.ToString(digest).Replace("-", "").ToLowerInvariant();
            if (string.IsNullOrEmpty(suppliedHmac) || !string.Equals(expectedHmac, suppliedHmac, StringComparison.OrdinalIgnoreCase))
            {
                context.Response.StatusCode = 401;
                context.Response.ContentType = "application/json";
                context.Response.Write("{\"error\":\"Invalid webhook signature\"}");
                return;
            }
        }

        // HubRise must be acknowledged before local order processing.
        // Database errors must never prevent the acknowledgement.
        try
        {
            var webhookLogId = LogWebhook(body, context);
            // HostingEnvironment.QueueBackgroundWorkItem, non ThreadPool.QueueUserWorkItem:
            // in ASP.NET classico un lavoro "fire and forget" avviato dopo che la risposta e'
            // gia' stata completata (CompleteRequest) non e' garantito che sopravviva - IIS puo'
            // interromperlo a meta'. QueueBackgroundWorkItem lo registra invece esplicitamente
            // presso l'hosting ASP.NET.
            System.Web.Hosting.HostingEnvironment.QueueBackgroundWorkItem(cancellationToken =>
                SaveOrderWithRetry(webhookLogId, body));
        }
        catch (Exception ex)
        {
            HubRiseIntegration.LogProcess("ERROR", "HubRiseWebhook: " + ex);
        }

        Acknowledge(context);
    }

    private bool IsDiagnosticsKeyValid(string key)
    {
        var expected = ConfigurationManager.AppSettings["HubRiseDiagnosticsKey"];
        return !string.IsNullOrEmpty(expected) && string.Equals(key, expected, StringComparison.Ordinal);
    }

    private void WriteDiagnostics(HttpContext context)
    {
        var result = new Dictionary<string, object>();
        try
        {
            using (var connection = HubRiseIntegration.OpenDatabase())
            {
                result["database"] = "connected";
                result["orders"] = Scalar(connection, "SELECT COUNT(*) FROM hubrise_order");
                result["webhooks"] = Scalar(connection, "SELECT COUNT(*) FROM hubrise_webhook_log");
                result["unprocessed_webhooks"] = Scalar(connection, "SELECT COUNT(*) FROM hubrise_webhook_log WHERE processed = 0");
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

    private long LogWebhook(string body, HttpContext context)
    {
        var headers = new StringBuilder();
        foreach (string key in context.Request.Headers.AllKeys)
        {
            if (string.Equals(key, "Authorization", StringComparison.OrdinalIgnoreCase) ||
                string.Equals(key, "Cookie", StringComparison.OrdinalIgnoreCase)) continue;
            headers.Append(key).Append('=').Append(context.Request.Headers[key]).Append(';');
        }
        using (var connection = HubRiseIntegration.OpenDatabase())
        using (var command = new MySqlCommand(@"
            INSERT INTO hubrise_webhook_log
                (received_at_utc, request_path, request_headers, payload, processed)
            VALUES
                (UTC_TIMESTAMP(), @path, @headers, @payload, 0)", connection))
        {
            command.CommandTimeout = CommandTimeoutSeconds;
            command.Parameters.AddWithValue("@path", context.Request.Path);
            command.Parameters.AddWithValue("@headers", headers.ToString());
            command.Parameters.AddWithValue("@payload", body);
            command.ExecuteNonQuery();
            return command.LastInsertedId;
        }
    }

    private void MarkWebhookProcessed(long webhookLogId)
    {
        using (var connection = HubRiseIntegration.OpenDatabase())
        using (var command = new MySqlCommand(
            "UPDATE hubrise_webhook_log SET processed = 1, processed_at_utc = UTC_TIMESTAMP() WHERE id = @id", connection))
        {
            command.CommandTimeout = CommandTimeoutSeconds;
            command.Parameters.AddWithValue("@id", webhookLogId);
            command.ExecuteNonQuery();
        }
    }

    private void SaveOrderWithRetry(long webhookLogId, string body)
    {
        const int maxAttempts = 3;
        for (var attempt = 1; attempt <= maxAttempts; attempt++)
        {
            try
            {
                HubRiseIntegration.SaveOrder(body);
                MarkWebhookProcessed(webhookLogId);
                return;
            }
            catch (Exception ex)
            {
                HubRiseIntegration.LogProcess("ERROR",
                    "HubRiseWebhook: tentativo " + attempt + "/" + maxAttempts + " fallito per webhook_log_id=" +
                    webhookLogId + ": " + ex);
                if (attempt < maxAttempts) Thread.Sleep(1500);
            }
        }
    }
}
