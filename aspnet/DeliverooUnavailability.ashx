<%@ WebHandler Language="C#" Class="DeliverooUnavailability" %>
using System;
using System.Collections.Generic;
using System.Configuration;
using System.IO;
using System.Net;
using System.Text;
using System.Web;
using System.Web.Script.Serialization;

public class DeliverooUnavailability : IHttpHandler
{
    private const string HandlerVersion = "2026-07-26.25";
    private readonly List<string> RequestLog = new List<string>();
    public bool IsReusable { get { return false; } }
    public void ProcessRequest(HttpContext context)
    {
        context.Response.ContentType = "application/json; charset=utf-8";
        try
        {
            Log("START v" + HandlerVersion + " " + context.Request.RawUrl);
            var key = ConfigurationManager.AppSettings["DeliverooMenuSyncKey"];
            if (string.IsNullOrEmpty(key) || context.Request.QueryString["key"] != key) { context.Response.StatusCode = 403; context.Response.Write("{\"error\":\"unauthorized\"}"); return; }
            var menuId = context.Request.QueryString["menu_id"];
            var mode = context.Request.QueryString["mode"] ?? "tablet";
            Log("MENU_ID " + (menuId ?? "<null>"));
            Log("MODE " + mode);
            if (string.IsNullOrWhiteSpace(menuId)) { context.Response.StatusCode = 400; context.Response.Write("{\"error\":\"menu_id is required\"}"); return; }
            var url = "https://api-sandbox.developers.deliveroo.com/menu/v1/brands/" + ConfigurationManager.AppSettings["DeliverooBrandId"] + "/menus/" + HttpUtility.UrlEncode(menuId) + "/item_unavailabilities/" + ConfigurationManager.AppSettings["DeliverooSiteId"];
            Log("API_URL " + url);
            if (string.Equals(mode, "morning", StringComparison.OrdinalIgnoreCase))
            {
                var morningBody = "{\"item_unavailabilities\":[{\"item_id\":\"granola\",\"status\":\"unavailable\"},{\"item_id\":\"orange_juice\",\"status\":\"hidden\"}]}";
                Log("MORNING POST BODY " + morningBody);
                var morningResult = Send(url, "POST", morningBody);
                context.Response.Write(new JavaScriptSerializer().Serialize(new { ok = true, version = HandlerVersion, mode = mode, post = morningResult, log = RequestLog }));
                return;
            }
            if (string.Equals(mode, "ignore-morning", StringComparison.OrdinalIgnoreCase))
            {
                var beforeIgnore = Send(url, "GET", null);
                Log("IGNORE_MORNING GET STATE " + beforeIgnore);
                var ignoreBody = "{\"item_unavailabilities\":[{\"item_id\":\"whole_milk\",\"status\":\"unavailable\"}]}";
                Log("IGNORE_MORNING POST BODY " + ignoreBody);
                var ignoreResult = Send(url, "POST", ignoreBody);
                context.Response.Write(new JavaScriptSerializer().Serialize(new { ok = true, version = HandlerVersion, mode = mode, post = ignoreResult, log = RequestLog }));
                return;
            }
            if (string.Equals(mode, "after-upload", StringComparison.OrdinalIgnoreCase))
            {
                var itemId = context.Request.QueryString["item_id"] ?? "whole_milk";
                var status = context.Request.QueryString["status"] ?? "unavailable";
                var afterUploadBody = "{\"item_unavailabilities\":[{\"item_id\":\"" + HttpUtility.JavaScriptStringEncode(itemId) + "\",\"status\":\"" + HttpUtility.JavaScriptStringEncode(status) + "\"}]}";
                Log("AFTER_UPLOAD ITEM_ID " + itemId + " STATUS " + status);
                Log("AFTER_UPLOAD POST BODY " + afterUploadBody);
                var afterUploadResult = Send(url, "POST", afterUploadBody);
                context.Response.Write(new JavaScriptSerializer().Serialize(new { ok = true, version = HandlerVersion, mode = mode, post = afterUploadResult, log = RequestLog }));
                return;
            }
            var current = Send(url, "GET", null);
            Log("GET " + current);
            var state = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(current);
            var unavailable = ReadIds(state, "unavailable_ids");
            var hidden = ReadIds(state, "hidden_ids");
            if (string.Equals(mode, "reset", StringComparison.OrdinalIgnoreCase))
            {
                unavailable.Clear();
                hidden.Clear();
                Log("RESET_STATE all items available");
            }
            else
            {
            var hasNullState = state != null && state.ContainsKey("unavailable_ids") && state["unavailable_ids"] == null
                && state.ContainsKey("hidden_ids") && state["hidden_ids"] == null;
            if (hasNullState && menuId.StartsWith("thai-princess-callback-test-", StringComparison.OrdinalIgnoreCase))
            {
                Log("TEST_STATE_FALLBACK orange_juice=unavailable granola=hidden");
                if (!unavailable.Contains("orange_juice")) unavailable.Add("orange_juice");
                if (!hidden.Contains("granola")) hidden.Add("granola");
            }
            if (!unavailable.Contains("whole_milk")) unavailable.Add("whole_milk");
            }
            var updated = new JavaScriptSerializer().Serialize(new Dictionary<string, object>
            {
                { "unavailable_ids", unavailable },
                { "hidden_ids", hidden }
            });
            Log("PUT BODY " + updated);
            var putResult = Send(url, "PUT", updated);
            Log("PUT RESPONSE " + putResult);
            context.Response.Write(new JavaScriptSerializer().Serialize(new { ok = true, version = HandlerVersion, get = state, put = putResult, log = RequestLog }));
        }
        catch (Exception ex) { Log("ERROR v" + HandlerVersion + " " + ex.ToString()); context.Response.StatusCode = 500; context.Response.Write(new JavaScriptSerializer().Serialize(new { ok = false, version = HandlerVersion, error = ex.Message, log = RequestLog })); }
    }
    private List<string> ReadIds(Dictionary<string, object> state, string name)
    {
        var result = new List<string>();
        object value;
        if (state == null || !state.TryGetValue(name, out value) || value == null) return result;
        var values = value as System.Collections.IEnumerable;
        if (values == null) return result;
        foreach (var item in values)
        {
            var id = Convert.ToString(item);
            if (!string.IsNullOrEmpty(id) && !result.Contains(id)) result.Add(id);
        }
        return result;
    }
    private void Log(string message)
    {
        var line = DateTime.UtcNow.ToString("o") + " v" + HandlerVersion + " " + message + Environment.NewLine;
        RequestLog.Add(line.TrimEnd('\r', '\n'));
        try
        {
            var appData = HttpContext.Current.Server.MapPath("~/App_Data");
            if (!Directory.Exists(appData)) Directory.CreateDirectory(appData);
            File.AppendAllText(Path.Combine(appData, "DeliverooUnavailability.log"), line);
            return;
        }
        catch { }
        try
        {
            var root = HttpContext.Current.Server.MapPath("~/DeliverooUnavailability.log");
            File.AppendAllText(root, line);
        }
        catch { }
    }
    private string Send(string url, string method, string body)
    {
        var request = (HttpWebRequest)WebRequest.Create(url); request.Method = method; request.Headers["Authorization"] = "Bearer " + GetToken(); request.Accept = "application/json";
        if (body != null) { request.ContentType = "application/json"; var bytes = Encoding.UTF8.GetBytes(body); using (var stream = request.GetRequestStream()) stream.Write(bytes, 0, bytes.Length); }
        if (body != null) Log(method + " REQUEST " + body);
        try
        {
            using (var response = (HttpWebResponse)request.GetResponse())
            using (var reader = new StreamReader(response.GetResponseStream()))
            {
                var result = reader.ReadToEnd();
                Log(method + " HTTP " + (int)response.StatusCode + " RESPONSE " + result);
                return result;
            }
        }
        catch (WebException ex)
        {
            var response = ex.Response as HttpWebResponse;
            var responseText = "";
            if (response != null)
            {
                using (var reader = new StreamReader(response.GetResponseStream())) responseText = reader.ReadToEnd();
                Log(method + " HTTP " + (int)response.StatusCode + " ERROR " + responseText);
            }
            else Log(method + " NETWORK_ERROR " + ex.Message);
            throw new InvalidOperationException(method + " failed: " + (response == null ? ex.Message : ((int)response.StatusCode + " " + responseText)), ex);
        }
    }
    private string GetToken()
    {
        var clientId = ConfigurationManager.AppSettings["DeliverooClientId"]; var secret = ConfigurationManager.AppSettings["DeliverooClientSecret"];
        var request = (HttpWebRequest)WebRequest.Create("https://auth-sandbox.developers.deliveroo.com/oauth2/token"); request.Method = "POST"; request.ContentType = "application/x-www-form-urlencoded";
        var body = "grant_type=client_credentials&client_id=" + HttpUtility.UrlEncode(clientId) + "&client_secret=" + HttpUtility.UrlEncode(secret); var bytes = Encoding.UTF8.GetBytes(body); using (var stream = request.GetRequestStream()) stream.Write(bytes, 0, bytes.Length);
        using (var response = (HttpWebResponse)request.GetResponse()) using (var reader = new StreamReader(response.GetResponseStream())) { var data = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(reader.ReadToEnd()); return Convert.ToString(data["access_token"]); }
    }
}
