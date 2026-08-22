<%@ WebHandler Language="C#" Class="DeliverooTestOrder" %>

using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Text;
using System.Web;
using System.Web.Script.Serialization;

public class DeliverooTestOrder : IHttpHandler
{
    public bool IsReusable { get { return false; } }

    public void ProcessRequest(HttpContext context)
    {
        context.Response.ContentType = "application/json; charset=utf-8";
        var configuredKey = System.Configuration.ConfigurationManager.AppSettings["DeliverooTestOrderKey"];
        if (string.IsNullOrEmpty(configuredKey) || !string.Equals(context.Request.QueryString["key"], configuredKey, StringComparison.Ordinal))
        {
            context.Response.StatusCode = 403;
            context.Response.Write("{\"error\":\"test not authorized\"}");
            return;
        }

        try
        {
            var payload = new Dictionary<string, object>();
            payload["order_type"] = "delivery";
            payload["market"] = "it";
            payload["restaurant_lat"] = 37.5;
            payload["restaurant_lon"] = 15.1;
            payload["order_notes"] = "Test menu Thai Princess";
            payload["items"] = new List<object> {
                new Dictionary<string, object> {
                    { "pos_item_id", "MU11001" },
                    { "quantity", 2 },
                    { "modifiers", new List<object> {
                        new Dictionary<string, object> { { "pos_item_id", "OM17001" }, { "quantity", 2 } }
                    } }
                }
            };
            payload["test_webhooks"] = new Dictionary<string, string> { { "new", "15s" }, { "accepted", "30s" } };
            var json = new JavaScriptSerializer().Serialize(payload);
            var response = CallDeliveroo(json);
            context.Response.Write(response);
        }
        catch (Exception ex)
        {
            context.Response.StatusCode = 500;
            context.Response.Write(new JavaScriptSerializer().Serialize(new { error = ex.Message }));
        }
    }

    private string CallDeliveroo(string json)
    {
        var token = GetToken();
        var baseUrl = System.Configuration.ConfigurationManager.AppSettings["DeliverooApiBaseUrl"] ?? "https://api-sandbox.developers.deliveroo.com";
        var request = (HttpWebRequest)WebRequest.Create(baseUrl.TrimEnd('/') + "/order/v1/orders/test_order/create");
        request.Method = "POST";
        request.ContentType = "application/json";
        request.Headers["Authorization"] = "Bearer " + token;
        var body = Encoding.UTF8.GetBytes(json);
        request.ContentLength = body.Length;
        using (var stream = request.GetRequestStream()) stream.Write(body, 0, body.Length);
        using (var response = (HttpWebResponse)request.GetResponse())
        using (var reader = new StreamReader(response.GetResponseStream())) return reader.ReadToEnd();
    }

    private string GetToken()
    {
        var config = System.Configuration.ConfigurationManager.AppSettings;
        var request = (HttpWebRequest)WebRequest.Create("https://auth-sandbox.developers.deliveroo.com/oauth2/token");
        request.Method = "POST";
        request.ContentType = "application/x-www-form-urlencoded";
        var form = "grant_type=client_credentials&client_id=" + HttpUtility.UrlEncode(config["DeliverooClientId"]) + "&client_secret=" + HttpUtility.UrlEncode(config["DeliverooClientSecret"]);
        var body = Encoding.UTF8.GetBytes(form);
        request.ContentLength = body.Length;
        using (var stream = request.GetRequestStream()) stream.Write(body, 0, body.Length);
        using (var response = (HttpWebResponse)request.GetResponse())
        using (var reader = new StreamReader(response.GetResponseStream()))
        {
            var result = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(reader.ReadToEnd());
            return Convert.ToString(result["access_token"]);
        }
    }
}
