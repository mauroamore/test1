using System;
using System.Collections.Generic;
using System.Configuration;
using System.IO;
using System.Net;
using System.Text;
using System.Web;
using System.Web.Script.Serialization;
using MySql.Data.MySqlClient;

/// <summary>
/// Shared production-safe plumbing for Deliveroo handlers.
/// Test-only menu fixtures must remain in the caller and behind an explicit
/// sandbox menu switch.
/// </summary>
public static class DeliverooIntegration
{
    public const int ConnectionTimeoutSeconds = 5;
    public const int CommandTimeoutSeconds = 5;

    public static string ApiBaseUrl
    {
        get { return (ConfigurationManager.AppSettings["DeliverooApiBaseUrl"] ?? "https://api-sandbox.developers.deliveroo.com").TrimEnd('/'); }
    }

    public static string MenuApiBaseUrl { get { return ApiBaseUrl + "/menu"; } }
    public static string OrderApiBaseUrl { get { return ApiBaseUrl + "/order"; } }

    public static MySqlConnection OpenDatabase()
    {
        var configured = ConfigurationManager.ConnectionStrings["MySqlConnectionString"];
        if (configured == null || string.IsNullOrWhiteSpace(configured.ConnectionString))
            throw new ConfigurationErrorsException("MySqlConnectionString is not configured.");

        var builder = new MySqlConnectionStringBuilder(configured.ConnectionString);
        builder.ConnectionTimeout = ConnectionTimeoutSeconds;
        var connection = new MySqlConnection(builder.ConnectionString);
        connection.Open();
        return connection;
    }

    public static string GetAccessToken()
    {
        var clientId = ConfigurationManager.AppSettings["DeliverooClientId"];
        var clientSecret = ConfigurationManager.AppSettings["DeliverooClientSecret"];
        if (string.IsNullOrWhiteSpace(clientId) || string.IsNullOrWhiteSpace(clientSecret))
            throw new ConfigurationErrorsException("Deliveroo OAuth credentials are not configured.");

        var request = (HttpWebRequest)WebRequest.Create(
            ConfigurationManager.AppSettings["DeliverooOAuthTokenUrl"] ??
            "https://auth-sandbox.developers.deliveroo.com/oauth2/token");
        request.Method = "POST";
        request.ContentType = "application/x-www-form-urlencoded";
        request.Timeout = 15000;
        request.ReadWriteTimeout = 15000;
        var body = "grant_type=client_credentials&client_id=" + HttpUtility.UrlEncode(clientId) +
                   "&client_secret=" + HttpUtility.UrlEncode(clientSecret);
        var bytes = Encoding.UTF8.GetBytes(body);
        request.ContentLength = bytes.Length;
        using (var stream = request.GetRequestStream()) stream.Write(bytes, 0, bytes.Length);
        using (var response = (HttpWebResponse)request.GetResponse())
        using (var reader = new StreamReader(response.GetResponseStream()))
        {
            var data = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(reader.ReadToEnd());
            var token = data == null || !data.ContainsKey("access_token") ? "" : Convert.ToString(data["access_token"]);
            if (string.IsNullOrWhiteSpace(token)) throw new InvalidOperationException("Deliveroo OAuth response has no access_token.");
            return token;
        }
    }

    public static HttpWebRequest CreateApiRequest(string url, string method)
    {
        var request = (HttpWebRequest)WebRequest.Create(url);
        request.Method = method;
        request.Accept = "application/json";
        request.ContentType = "application/json";
        request.Timeout = 15000;
        request.ReadWriteTimeout = 15000;
        request.Headers["Authorization"] = "Bearer " + GetAccessToken();
        return request;
    }
}
