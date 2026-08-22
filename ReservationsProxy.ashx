<%@ WebHandler Language="C#" Class="ReservationsProxy" %>

using System;
using System.IO;
using System.Net;
using System.Text;
using System.Web;

public class ReservationsProxy : IHttpHandler
{
    public bool IsReusable { get { return false; } }

    public void ProcessRequest(HttpContext context)
    {
        AddCors(context);
        context.Response.TrySkipIisCustomErrors = true;
        if (context.Request.HttpMethod == "OPTIONS")
        {
            context.Response.StatusCode = 204;
            return;
        }

        string method = (context.Request.QueryString["method"] ?? "").Trim();
        if (method != "GetReservations" && method != "UpdateReservation" && method != "InsertWalkin")
        {
            WriteJson(context, 400, "{\"error\":\"Metodo prenotazioni non valido\"}");
            return;
        }

        try
        {
            string body;
            using (var reader = new StreamReader(context.Request.InputStream, context.Request.ContentEncoding ?? Encoding.UTF8))
                body = reader.ReadToEnd();

            var request = (HttpWebRequest)WebRequest.Create(GetServiceUrl(context) + method);
            request.Method = "POST";
            request.ContentType = "application/json; charset=utf-8";
            request.Accept = "application/json";
            var bytes = Encoding.UTF8.GetBytes(body ?? "{}");
            request.ContentLength = bytes.Length;
            using (var stream = request.GetRequestStream()) stream.Write(bytes, 0, bytes.Length);

            using (var response = (HttpWebResponse)request.GetResponse())
            using (var reader = new StreamReader(response.GetResponseStream()))
            {
                context.Response.StatusCode = (int)response.StatusCode;
                context.Response.ContentType = "application/json; charset=utf-8";
                context.Response.Write(reader.ReadToEnd());
            }
        }
        catch (WebException ex)
        {
            var response = ex.Response as HttpWebResponse;
            string details = ex.Message;
            if (response != null)
            {
                using (var reader = new StreamReader(response.GetResponseStream())) details = reader.ReadToEnd();
                context.Response.StatusCode = (int)response.StatusCode;
            }
            WriteJson(context, context.Response.StatusCode >= 400 ? context.Response.StatusCode : 502,
                "{\"error\":\"" + HttpUtility.JavaScriptStringEncode(details) + "\"}");
        }
        catch (Exception ex)
        {
            WriteJson(context, 500, "{\"error\":\"" + HttpUtility.JavaScriptStringEncode(ex.Message) + "\"}");
        }
    }

    private static void AddCors(HttpContext context)
    {
        context.Response.Headers["Access-Control-Allow-Origin"] = "*";
        context.Response.Headers["Access-Control-Allow-Methods"] = "POST, OPTIONS";
        context.Response.Headers["Access-Control-Allow-Headers"] = "Content-Type, Accept";
    }

    private static string GetServiceUrl(HttpContext context)
    {
        var host = context.Request.Url.Host.ToLowerInvariant();
        if (host != "servizi.thaiprincess.it" &&
            host != "thaiprincess.it" &&
            host != "www.thaiprincess.it")
            throw new InvalidOperationException("Host non autorizzato.");

        return context.Request.Url.GetLeftPart(UriPartial.Authority) + "/Sigonella.aspx/";
    }

    private static void WriteJson(HttpContext context, int status, string json)
    {
        context.Response.StatusCode = status;
        context.Response.ContentType = "application/json; charset=utf-8";
        context.Response.Write(json);
    }
}
