<%@ WebHandler Language="C#" Class="RestaurantOperationsProxy" %>

using System;
using System.Configuration;
using System.IO;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Web;
using System.Web.Script.Serialization;

public class RestaurantOperationsProxy : IHttpHandler
{
    private const string CookieName = "restaurant_operations_token";

    public bool IsReusable { get { return false; } }

    public void ProcessRequest(HttpContext context)
    {
        context.Response.TrySkipIisCustomErrors = true;
        if (!IsSameOrigin(context)) { WriteJson(context, 403, "{\"error\":\"Origine non autorizzata\"}"); return; }
        if (context.Request.HttpMethod == "GET" && context.Request.QueryString["method"] == "token") { IssueToken(context); return; }
        if (context.Request.HttpMethod != "POST" || !ValidToken(context)) { WriteJson(context, 403, "{\"error\":\"Token operativo non valido\"}"); return; }
        var method = (context.Request.QueryString["method"] ?? "").Trim();
        if (method != "GetState" && method != "OpenTable" && method != "AdoptWalkIn" && method != "MoveReservation" && method != "ClearReservation" && method != "GetCommandStatus") { WriteJson(context, 400, "{\"error\":\"Metodo operativo non valido\"}"); return; }
        try
        {
            string body;
            using (var reader = new StreamReader(context.Request.InputStream, context.Request.ContentEncoding ?? Encoding.UTF8)) body = reader.ReadToEnd();
            var upstreamBody = method == "GetState" || method == "GetCommandStatus" ? (body ?? "{}") : new JavaScriptSerializer().Serialize(new { payload = body ?? "{}" });
            var request = (HttpWebRequest)WebRequest.Create(GetServiceUrl(context) + method);
            request.Method = "POST"; request.ContentType = "application/json; charset=utf-8"; request.Accept = "application/json";
            request.Headers["X-Restaurant-Operations-Key"] = ConfigurationManager.AppSettings["RestaurantSyncKey"] ?? "";
            var bytes = Encoding.UTF8.GetBytes(upstreamBody); request.ContentLength = bytes.Length;
            using (var stream = request.GetRequestStream()) stream.Write(bytes, 0, bytes.Length);
            using (var response = (HttpWebResponse)request.GetResponse()) using (var reader = new StreamReader(response.GetResponseStream())) { context.Response.StatusCode = (int)response.StatusCode; context.Response.ContentType = "application/json; charset=utf-8"; context.Response.Write(reader.ReadToEnd()); }
        }
        catch (WebException ex) { WriteJson(context, 502, "{\"error\":\"" + HttpUtility.JavaScriptStringEncode(ex.Message) + "\"}"); }
        catch (Exception ex) { WriteJson(context, 500, "{\"error\":\"" + HttpUtility.JavaScriptStringEncode(ex.Message) + "\"}"); }
    }

    private static void IssueToken(HttpContext context)
    {
        var bytes = new byte[32]; using (var random = RandomNumberGenerator.Create()) random.GetBytes(bytes);
        var token = Convert.ToBase64String(bytes).Replace("+", "-").Replace("/", "_").TrimEnd('=');
        context.Response.Cookies.Add(new HttpCookie(CookieName, token) { HttpOnly = true, Secure = true, SameSite = SameSiteMode.Strict, Path = "/" });
        WriteJson(context, 200, new JavaScriptSerializer().Serialize(new { token = token }));
    }

    private static bool ValidToken(HttpContext context)
    {
        var cookie = context.Request.Cookies[CookieName];
        var header = context.Request.Headers["X-Restaurant-Operations-Token"];
        return cookie != null && !String.IsNullOrEmpty(header) && String.Equals(cookie.Value, header, StringComparison.Ordinal);
    }

    private static bool IsSameOrigin(HttpContext context)
    {
        var origin = context.Request.Headers["Origin"];
        var currentOrigin = context.Request.Url.GetLeftPart(UriPartial.Authority).TrimEnd('/');
        if (!IsAllowedHost(context.Request.Url.Host)) return false;
        if (!String.IsNullOrWhiteSpace(origin)) return String.Equals(origin.TrimEnd('/'), currentOrigin, StringComparison.OrdinalIgnoreCase);
        var referer = context.Request.UrlReferrer;
        return referer != null && String.Equals(referer.GetLeftPart(UriPartial.Authority).TrimEnd('/'), currentOrigin, StringComparison.OrdinalIgnoreCase);
    }

    private static string GetServiceUrl(HttpContext context)
    {
        var host = context.Request.Url.Host.ToLowerInvariant();
        if (!IsAllowedHost(host)) throw new InvalidOperationException("Host non autorizzato.");
        return context.Request.Url.GetLeftPart(UriPartial.Authority) + "/RestaurantOperationsService.asmx/";
    }

    private static bool IsAllowedHost(string host)
    {
        return host == "servizi.thaiprincess.it" || host == "thaiprincess.it" || host == "www.thaiprincess.it";
    }

    private static void WriteJson(HttpContext context, int status, string json) { context.Response.StatusCode = status; context.Response.ContentType = "application/json; charset=utf-8"; context.Response.Write(json); }
}
