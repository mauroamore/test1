<%@ WebHandler Language="C#" Class="HubRiseOrderStatus" %>

using System;
using System.Collections.Generic;
using System.Configuration;
using System.IO;
using System.Net;
using System.Text;
using System.Web;
using System.Web.Script.Serialization;

/// <summary>
/// Aggiornamento di stato ordine verso HubRise, guidato dalle azioni dell'operatore in cassa
/// (mai automatico oltre alla conferma "received" gia' gestita in HubRiseWebhook.ashx). Chiamato
/// dal Node locale (server.js), che tiene la chiave lato server e non la espone al browser.
/// Stati ammessi: accepted, in_preparation, awaiting_collection, in_delivery, completed,
/// rejected, cancelled, delivery_failed (vedi documentazione Orders API di HubRise).
/// </summary>
public class HubRiseOrderStatus : IHttpHandler
{
    private static readonly string[] AllowedStatuses =
    {
        "accepted", "in_preparation", "awaiting_collection", "in_delivery",
        "completed", "rejected", "cancelled", "delivery_failed"
    };

    public bool IsReusable { get { return false; } }

    public void ProcessRequest(HttpContext context)
    {
        context.Response.ContentType = "application/json";

        if (!string.Equals(context.Request.HttpMethod, "POST", StringComparison.OrdinalIgnoreCase))
        {
            context.Response.StatusCode = 405;
            context.Response.Write("{\"error\":\"POST required\"}");
            return;
        }

        var expectedKey = ConfigurationManager.AppSettings["HubRiseOrderStatusKey"];
        var suppliedKey = context.Request.Headers["X-HubRise-Status-Key"];
        if (string.IsNullOrEmpty(expectedKey) || !string.Equals(expectedKey, suppliedKey, StringComparison.Ordinal))
        {
            context.Response.StatusCode = 401;
            context.Response.Write("{\"error\":\"Unauthorized\"}");
            return;
        }

        string body;
        using (var reader = new StreamReader(context.Request.InputStream, Encoding.UTF8)) body = reader.ReadToEnd();

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

        var externalOrderId = request != null && request.ContainsKey("external_order_id")
            ? Convert.ToString(request["external_order_id"]) : null;
        var status = request != null && request.ContainsKey("status")
            ? Convert.ToString(request["status"]) : null;
        var confirmedTime = request != null && request.ContainsKey("confirmed_time")
            ? Convert.ToString(request["confirmed_time"]) : null;

        if (string.IsNullOrWhiteSpace(externalOrderId) || string.IsNullOrWhiteSpace(status))
        {
            context.Response.StatusCode = 400;
            context.Response.Write("{\"error\":\"external_order_id e status sono obbligatori\"}");
            return;
        }

        if (Array.IndexOf(AllowedStatuses, status) < 0)
        {
            context.Response.StatusCode = 400;
            context.Response.Write("{\"error\":\"Stato non valido: " + status + "\"}");
            return;
        }

        try
        {
            HubRiseIntegration.UpdateOrderStatus(externalOrderId, status, confirmedTime);
            context.Response.Write("{\"ok\":true}");
        }
        catch (WebException ex)
        {
            var response = ex.Response as HttpWebResponse;
            var detail = "";
            if (response != null)
            {
                using (var reader = new StreamReader(response.GetResponseStream())) detail = reader.ReadToEnd();
            }
            HubRiseIntegration.LogProcess("ERROR", "HubRiseOrderStatus: " + ex.Message + " " + detail);
            context.Response.StatusCode = 502;
            context.Response.Write("{\"ok\":false,\"error\":\"hubrise_status_update_failed\",\"detail\":" +
                (string.IsNullOrWhiteSpace(detail) ? "null" : new JavaScriptSerializer().Serialize(detail)) + "}");
        }
        catch (Exception ex)
        {
            HubRiseIntegration.LogProcess("ERROR", "HubRiseOrderStatus: " + ex);
            context.Response.StatusCode = 500;
            context.Response.Write("{\"ok\":false,\"error\":\"internal_error\"}");
        }
    }
}
