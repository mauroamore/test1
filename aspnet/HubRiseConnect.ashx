<%@ WebHandler Language="C#" Class="HubRiseConnect" %>

using System;
using System.Collections.Generic;
using System.Configuration;
using System.IO;
using System.Net;
using System.Text;
using System.Web;
using System.Web.Script.Serialization;
using MySql.Data.MySqlClient;

public class HubRiseConnect : IHttpHandler
{
    public bool IsReusable { get { return false; } }

    public void ProcessRequest(HttpContext context)
    {
        context.Response.ContentType = "application/json";

        var expectedKey = ConfigurationManager.AppSettings["HubRiseConnectKey"];
        var suppliedKey = context.Request.QueryString["key"];
        if (string.IsNullOrEmpty(expectedKey) || !string.Equals(expectedKey, suppliedKey, StringComparison.Ordinal))
        {
            context.Response.StatusCode = 401;
            context.Response.Write("{\"error\":\"Unauthorized\"}");
            return;
        }

        try
        {
            if (context.Request.QueryString["revoke"] == "1")
            {
                Revoke(context);
                return;
            }

            if (context.Request.QueryString["show_config"] == "1")
            {
                ShowConfig(context);
                return;
            }

            if (context.Request.QueryString["register_webhook"] == "1")
            {
                RegisterWebhook(context);
                return;
            }

            var code = context.Request.QueryString["code"];
            if (string.IsNullOrEmpty(code))
            {
                ShowAuthorizeUrl(context);
                return;
            }

            ExchangeCode(context, code);
        }
        catch (WebException ex)
        {
            var response = ex.Response as HttpWebResponse;
            var detail = "";
            if (response != null)
            {
                using (var reader = new StreamReader(response.GetResponseStream())) detail = reader.ReadToEnd();
            }
            HubRiseIntegration.LogProcess("ERROR", "HubRiseConnect: " + ex.Message + " " + detail);
            context.Response.StatusCode = 502;
            context.Response.Write("{\"ok\":false,\"error\":\"hubrise_connect_failed\"}");
        }
        catch (Exception ex)
        {
            HubRiseIntegration.LogProcess("ERROR", "HubRiseConnect: " + ex.Message);
            context.Response.StatusCode = 500;
            context.Response.Write("{\"ok\":false,\"error\":\"internal_error\"}");
        }
    }

    private void ShowAuthorizeUrl(HttpContext context)
    {
        var clientId = ConfigurationManager.AppSettings["HubRiseClientId"];
        var scope = ConfigurationManager.AppSettings["HubRiseScope"] ?? "location[orders.write,customer_list.write]";
        var redirectUri = ConfigurationManager.AppSettings["HubRiseRedirectUri"] ?? "urn:ietf:wg:oauth:2.0:oob";
        if (string.IsNullOrEmpty(clientId))
        {
            context.Response.StatusCode = 500;
            context.Response.ContentType = "application/json";
            context.Response.Write("{\"error\":\"HubRiseClientId non configurato\"}");
            return;
        }

        var url = HubRiseIntegration.ManagerBaseUrl + "/oauth2/v1/authorize"
            + "?client_id=" + HttpUtility.UrlEncode(clientId)
            + "&redirect_uri=" + HttpUtility.UrlEncode(redirectUri)
            + "&scope=" + HttpUtility.UrlEncode(scope);

        if (string.Equals(context.Request.QueryString["format"], "json", StringComparison.OrdinalIgnoreCase))
        {
            context.Response.ContentType = "application/json";
            context.Response.Write("{\"authorize_url\":\"" + url.Replace("\"", "\\\"") +
                "\",\"instructions\":\"Apri questo URL, autorizza l'accesso, poi richiama HubRiseConnect.ashx?key=...&code=IL_CODICE_MOSTRATO\"}");
            return;
        }

        // Redirect vero verso la pagina di autorizzazione HubRise: aprendo questo URL nel
        // browser si arriva direttamente alla schermata di consenso, invece di vedere solo
        // un JSON a schermo.
        context.Response.Redirect(url, true);
    }

    private void ExchangeCode(HttpContext context, string code)
    {
        var clientId = ConfigurationManager.AppSettings["HubRiseClientId"];
        var clientSecret = ConfigurationManager.AppSettings["HubRiseClientSecret"];
        var redirectUri = ConfigurationManager.AppSettings["HubRiseRedirectUri"] ?? "urn:ietf:wg:oauth:2.0:oob";
        if (string.IsNullOrEmpty(clientId) || string.IsNullOrEmpty(clientSecret))
        {
            context.Response.StatusCode = 500;
            context.Response.Write("{\"error\":\"Credenziali OAuth HubRise non configurate\"}");
            return;
        }

        var request = (HttpWebRequest)WebRequest.Create(HubRiseIntegration.ManagerBaseUrl + "/oauth2/v1/token");
        request.Method = "POST";
        request.ContentType = "application/x-www-form-urlencoded";
        request.Timeout = 15000;
        request.ReadWriteTimeout = 15000;
        var basicAuth = Convert.ToBase64String(Encoding.UTF8.GetBytes(clientId + ":" + clientSecret));
        request.Headers["Authorization"] = "Basic " + basicAuth;

        var body = "grant_type=authorization_code&code=" + HttpUtility.UrlEncode(code) +
            "&redirect_uri=" + HttpUtility.UrlEncode(redirectUri);
        var bytes = Encoding.UTF8.GetBytes(body);
        request.ContentLength = bytes.Length;
        using (var stream = request.GetRequestStream()) stream.Write(bytes, 0, bytes.Length);

        Dictionary<string, object> data;
        using (var response = (HttpWebResponse)request.GetResponse())
        using (var reader = new StreamReader(response.GetResponseStream()))
        {
            data = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(reader.ReadToEnd());
        }

        var accessToken = data != null && data.ContainsKey("access_token") ? Convert.ToString(data["access_token"]) : null;
        if (string.IsNullOrEmpty(accessToken))
        {
            context.Response.StatusCode = 502;
            context.Response.Write("{\"ok\":false,\"error\":\"hubrise_no_access_token\"}");
            return;
        }

        var accountId = GetString(data, "account_id");
        var locationId = GetString(data, "location_id");
        var catalogId = GetString(data, "catalog_id");
        var customerListId = GetString(data, "customer_list_id");
        var scope = ConfigurationManager.AppSettings["HubRiseScope"] ?? "location[orders.write,customer_list.write]";

        using (var connection = HubRiseIntegration.OpenDatabase())
        using (var command = new MySqlCommand(@"
            INSERT INTO hubrise_connection
                (account_id, location_id, catalog_id, customer_list_id, access_token, scope, connected_at_utc)
            VALUES
                (@accountId, @locationId, @catalogId, @customerListId, @accessToken, @scope, UTC_TIMESTAMP())", connection))
        {
            command.Parameters.AddWithValue("@accountId", (object)accountId ?? DBNull.Value);
            command.Parameters.AddWithValue("@locationId", (object)locationId ?? DBNull.Value);
            command.Parameters.AddWithValue("@catalogId", (object)catalogId ?? DBNull.Value);
            command.Parameters.AddWithValue("@customerListId", (object)customerListId ?? DBNull.Value);
            command.Parameters.AddWithValue("@accessToken", accessToken);
            command.Parameters.AddWithValue("@scope", scope);
            command.ExecuteNonQuery();
        }

        HubRiseIntegration.LogProcess("INFO", "HubRiseConnect: nuova connessione stabilita per location " + locationId);

        var masked = accessToken.Length > 8
            ? accessToken.Substring(0, 4) + "..." + accessToken.Substring(accessToken.Length - 4)
            : "****";
        context.Response.Write("{\"ok\":true,\"account_id\":\"" + accountId + "\",\"location_id\":\"" + locationId +
            "\",\"catalog_id\":\"" + catalogId + "\",\"access_token_preview\":\"" + masked + "\"}");
    }

    private void Revoke(HttpContext context)
    {
        HubRiseIntegration.HubRiseConnectionInfo current;
        try
        {
            current = HubRiseIntegration.GetConnection();
        }
        catch (InvalidOperationException)
        {
            context.Response.Write("{\"ok\":true,\"note\":\"Nessuna connessione attiva da revocare\"}");
            return;
        }

        var request = (HttpWebRequest)WebRequest.Create(HubRiseIntegration.ManagerBaseUrl + "/oauth2/v1/revoke");
        request.Method = "POST";
        request.ContentType = "application/x-www-form-urlencoded";
        request.Timeout = 15000;
        var body = "token=" + HttpUtility.UrlEncode(current.AccessToken);
        var bytes = Encoding.UTF8.GetBytes(body);
        request.ContentLength = bytes.Length;
        using (var stream = request.GetRequestStream()) stream.Write(bytes, 0, bytes.Length);
        using (var response = (HttpWebResponse)request.GetResponse()) { }

        using (var connection = HubRiseIntegration.OpenDatabase())
        using (var command = new MySqlCommand(
            "UPDATE hubrise_connection SET revoked_at_utc = UTC_TIMESTAMP() WHERE revoked_at_utc IS NULL", connection))
        {
            command.ExecuteNonQuery();
        }

        HubRiseIntegration.LogProcess("INFO", "HubRiseConnect: connessione revocata.");
        context.Response.Write("{\"ok\":true,\"revoked\":true}");
    }

    // Confronto diagnostico: mostra cosa il server legge davvero da web.config, mascherando il
    // secret (mai per intero), per escludere typo/spazi nascosti/versioni non salvate.
    private void ShowConfig(HttpContext context)
    {
        var clientId = ConfigurationManager.AppSettings["HubRiseClientId"] ?? "";
        var clientSecret = ConfigurationManager.AppSettings["HubRiseClientSecret"] ?? "";
        var scope = ConfigurationManager.AppSettings["HubRiseScope"] ?? "";
        var redirectUri = ConfigurationManager.AppSettings["HubRiseRedirectUri"] ?? "";

        context.Response.Write(new JavaScriptSerializer().Serialize(new Dictionary<string, object>
        {
            { "client_id", clientId },
            { "client_id_length", clientId.Length },
            { "client_secret_length", clientSecret.Length },
            { "client_secret_preview", MaskSecret(clientSecret) },
            { "client_secret_has_leading_or_trailing_whitespace", clientSecret != clientSecret.Trim() },
            { "scope", scope },
            { "redirect_uri", redirectUri }
        }));
    }

    private static string MaskSecret(string value)
    {
        if (string.IsNullOrEmpty(value)) return "(vuoto)";
        if (value.Length <= 8) return new string('*', value.Length);
        return value.Substring(0, 4) + new string('*', value.Length - 8) + value.Substring(value.Length - 4);
    }

    // HubRise non ha una schermata nel back office per registrare il webhook: si fa con
    // una chiamata POST /callback autenticata col token della connessione gia' stabilita.
    private void RegisterWebhook(HttpContext context)
    {
        var webhookSecret = ConfigurationManager.AppSettings["HubRiseWebhookSecret"];
        if (string.IsNullOrEmpty(webhookSecret))
        {
            context.Response.StatusCode = 500;
            context.Response.Write("{\"error\":\"HubRiseWebhookSecret non configurato\"}");
            return;
        }

        var callbackUrl = context.Request.Url.Scheme + "://" + context.Request.Url.Authority +
            "/HubRiseWebhook.ashx?wh=" + HttpUtility.UrlEncode(webhookSecret);

        var payload = new JavaScriptSerializer().Serialize(new Dictionary<string, object>
        {
            { "url", callbackUrl },
            { "events", new Dictionary<string, object> { { "order", new[] { "create", "update" } } } }
        });

        var request = HubRiseIntegration.CreateApiRequest(HubRiseIntegration.ApiBaseUrl + "/callback", "POST");
        var bytes = Encoding.UTF8.GetBytes(payload);
        request.ContentLength = bytes.Length;
        using (var stream = request.GetRequestStream()) stream.Write(bytes, 0, bytes.Length);

        using (var response = (HttpWebResponse)request.GetResponse())
        using (var reader = new StreamReader(response.GetResponseStream()))
        {
            var responseBody = reader.ReadToEnd();
            HubRiseIntegration.LogProcess("INFO", "HubRiseConnect: webhook registrato su " + callbackUrl);
            context.Response.Write("{\"ok\":true,\"callback_url\":\"" + callbackUrl.Replace("\"", "\\\"") +
                "\",\"hubrise_response\":" + (string.IsNullOrWhiteSpace(responseBody) ? "null" : responseBody) + "}");
        }
    }

    private static string GetString(Dictionary<string, object> data, string key)
    {
        object value;
        return data != null && data.TryGetValue(key, out value) && value != null ? Convert.ToString(value) : null;
    }
}
