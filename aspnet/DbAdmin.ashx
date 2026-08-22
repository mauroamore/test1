<%@ WebHandler Language="C#" Class="DbAdmin" %>

using System;
using System.Collections.Generic;
using System.Configuration;
using System.IO;
using System.Text;
using System.Web;
using System.Web.Script.Serialization;
using MySql.Data.MySqlClient;

/// <summary>
/// Endpoint di amministrazione DB generico (lettura e scrittura), protetto da una chiave
/// condivisa in header. Esegue SQL libero fornito dal chiamante: equivale ad accesso diretto
/// al database, va trattato come una password root. Ogni esecuzione viene loggata in
/// db_admin_log (testo della query, esito, righe interessate/restituite, errore) per audit.
/// Solo POST, chiave in header (non in query string) per non lasciarla in log/cronologia.
/// </summary>
public class DbAdmin : IHttpHandler
{
    private const int CommandTimeoutSeconds = 25;

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

        var expectedKey = ConfigurationManager.AppSettings["DbAdminKey"];
        var suppliedKey = context.Request.Headers["X-Db-Admin-Key"];
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
            context.Response.Write("{\"error\":\"Body JSON non valido: " + EscapeJson(ex.Message) + "\"}");
            return;
        }

        var sql = request != null && request.ContainsKey("sql") ? Convert.ToString(request["sql"]) : null;
        if (string.IsNullOrWhiteSpace(sql))
        {
            context.Response.StatusCode = 400;
            context.Response.Write("{\"error\":\"Campo 'sql' mancante\"}");
            return;
        }
        var parameters = request != null && request.ContainsKey("params")
            ? request["params"] as Dictionary<string, object>
            : null;

        var isQuery = LooksLikeQuery(sql);

        try
        {
            using (var connection = OpenDatabase())
            using (var command = new MySqlCommand(sql, connection))
            {
                command.CommandTimeout = CommandTimeoutSeconds;
                if (parameters != null)
                {
                    foreach (var pair in parameters)
                        command.Parameters.AddWithValue(pair.Key, pair.Value ?? DBNull.Value);
                }

                if (isQuery)
                {
                    var rows = new List<object>();
                    using (var dataReader = command.ExecuteReader())
                    {
                        while (dataReader.Read())
                        {
                            var row = new Dictionary<string, object>();
                            for (var i = 0; i < dataReader.FieldCount; i++)
                            {
                                var value = dataReader.GetValue(i);
                                row[dataReader.GetName(i)] = value is DBNull ? null : value;
                            }
                            rows.Add(row);
                        }
                    }
                    LogExecution(sql, true, rows.Count, null);
                    context.Response.Write(new JavaScriptSerializer().Serialize(new Dictionary<string, object>
                    {
                        { "rows", rows },
                        { "count", rows.Count }
                    }));
                }
                else
                {
                    var affected = command.ExecuteNonQuery();
                    LogExecution(sql, true, affected, null);
                    context.Response.Write("{\"affected\":" + affected + "}");
                }
            }
        }
        catch (Exception ex)
        {
            LogExecution(sql, false, null, ex.Message);
            context.Response.StatusCode = 500;
            context.Response.Write("{\"error\":\"" + EscapeJson(ex.Message) + "\"}");
        }
    }

    private static bool LooksLikeQuery(string sql)
    {
        var trimmed = sql.TrimStart().ToUpperInvariant();
        return trimmed.StartsWith("SELECT") || trimmed.StartsWith("SHOW") ||
               trimmed.StartsWith("DESCRIBE") || trimmed.StartsWith("DESC ") ||
               trimmed.StartsWith("EXPLAIN");
    }

    private static MySqlConnection OpenDatabase()
    {
        var configured = ConfigurationManager.ConnectionStrings["MySqlConnectionString"];
        if (configured == null || string.IsNullOrWhiteSpace(configured.ConnectionString))
            throw new ConfigurationErrorsException("MySqlConnectionString is not configured.");

        var builder = new MySqlConnectionStringBuilder(configured.ConnectionString);
        builder.ConnectionTimeout = 15;
        // Chiamate rare e sparse nel tempo: senza questo, una connessione presa dal pool
        // puo' essere gia' stata chiusa dal server (wait_timeout) e fallire con un
        // SocketException al primo uso. Niente pooling = sempre connessione fresca.
        builder.Pooling = false;
        var connection = new MySqlConnection(builder.ConnectionString);
        connection.Open();
        return connection;
    }

    private static void LogExecution(string sql, bool success, int? rowsAffectedOrReturned, string errorMessage)
    {
        try
        {
            using (var connection = OpenDatabase())
            using (var command = new MySqlCommand(@"
                INSERT INTO db_admin_log (sql_text, success, rows_affected_or_returned, error_message)
                VALUES (@sql, @success, @rows, @error)", connection))
            {
                command.CommandTimeout = 5;
                command.Parameters.AddWithValue("@sql", sql);
                command.Parameters.AddWithValue("@success", success ? 1 : 0);
                command.Parameters.AddWithValue("@rows", (object)rowsAffectedOrReturned ?? DBNull.Value);
                command.Parameters.AddWithValue("@error", (object)errorMessage ?? DBNull.Value);
                command.ExecuteNonQuery();
            }
        }
        catch
        {
            // Il log di audit non deve mai far fallire la risposta principale.
        }
    }

    private static string EscapeJson(string value)
    {
        return (value ?? "").Replace("\\", "\\\\").Replace("\"", "\\\"").Replace("\r", "").Replace("\n", " ");
    }
}
