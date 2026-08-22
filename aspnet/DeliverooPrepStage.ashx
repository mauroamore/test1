<%@ WebHandler Language="C#" Class="DeliverooPrepStage" %>

using System;
using System.Collections.Generic;
using System.Configuration;
using System.IO;
using System.Net;
using System.Text;
using System.Web;
using System.Web.Script.Serialization;

public class DeliverooPrepStage : IHttpHandler
{
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

        var expectedKey = ConfigurationManager.AppSettings["DeliverooPrepStageKey"];
        if (string.IsNullOrEmpty(expectedKey))
            expectedKey = ConfigurationManager.AppSettings["DeliverooDiagnosticsKey"];
        var suppliedKey = context.Request.Headers["X-Prep-Stage-Key"];
        if (string.IsNullOrEmpty(expectedKey) || !string.Equals(expectedKey, suppliedKey, StringComparison.Ordinal))
        {
            context.Response.StatusCode = 401;
            context.Response.Write("{\"error\":\"Unauthorized\"}");
            return;
        }

        try
        {
            string body;
            using (var reader = new StreamReader(context.Request.InputStream, Encoding.UTF8)) body = reader.ReadToEnd();
            var data = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(body);
            var orderId = data.ContainsKey("order_id") ? Convert.ToString(data["order_id"]) : "";
            var stage = data.ContainsKey("stage") ? Convert.ToString(data["stage"]) : "";
            var allowed = new[] { "in_kitchen", "ready_for_collection_soon", "ready_for_collection", "collected" };
            if (string.IsNullOrEmpty(orderId) || Array.IndexOf(allowed, stage) < 0)
            {
                context.Response.StatusCode = 400;
                context.Response.Write("{\"error\":\"Invalid order_id or stage\"}");
                return;
            }

            var request = DeliverooIntegration.CreateApiRequest(
                DeliverooIntegration.OrderApiBaseUrl + "/v1/orders/" + HttpUtility.UrlEncode(orderId) + "/prep_stage", "POST");
            var payload = "{\"stage\":\"" + stage + "\",\"occurred_at\":\"" + DateTime.UtcNow.ToString("o") + "\"}";
            var bytes = Encoding.UTF8.GetBytes(payload);
            request.ContentLength = bytes.Length;
            using (var stream = request.GetRequestStream()) stream.Write(bytes, 0, bytes.Length);
            using (var response = (HttpWebResponse)request.GetResponse())
            {
                context.Response.StatusCode = (int)response.StatusCode;
                context.Response.Write("{\"ok\":true,\"status\":" + (int)response.StatusCode + "}");
            }
        }
        catch (WebException ex)
        {
            var response = ex.Response as HttpWebResponse;
            context.Response.StatusCode = response == null ? 502 : (int)response.StatusCode;
            context.Response.Write("{\"ok\":false,\"error\":\"prep_stage_failed\"}");
        }
    }

}
