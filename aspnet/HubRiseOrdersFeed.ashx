<%@ WebHandler Language="C#" Class="HubRiseOrdersFeed" %>

using System;
using System.Collections.Generic;
using System.Configuration;
using System.Text.RegularExpressions;
using System.Web;
using System.Web.Script.Serialization;
using MySql.Data.MySqlClient;

/// <summary>
/// Feed consumato dal Node locale (server.js) per far arrivare gli ordini HubRise alla schermata
/// comande. Pensato per un unico poller (il processo server.js del ristorante): ogni ordine
/// restituito viene marcato come "fetched_by_pos_at_utc" e non ricompare nelle chiamate successive.
/// Per la visibilita' esterna (monitor read-only, multi-lettore) si usa invece HubRiseService.asmx,
/// che non consuma nulla.
/// </summary>
public class HubRiseOrdersFeed : IHttpHandler
{
    private const int CommandTimeoutSeconds = 5;
    private const int MaxOrdersPerRequest = 50;

    public bool IsReusable { get { return false; } }

    public void ProcessRequest(HttpContext context)
    {
        context.Response.ContentType = "application/json";

        var expectedKey = ConfigurationManager.AppSettings["HubRiseOrdersFeedKey"];
        var suppliedKey = context.Request.QueryString["key"];
        if (string.IsNullOrEmpty(expectedKey) || !string.Equals(expectedKey, suppliedKey, StringComparison.Ordinal))
        {
            context.Response.StatusCode = 401;
            context.Response.Write("{\"error\":\"Unauthorized\"}");
            return;
        }

        try
        {
            var orders = FetchAndMarkPendingExternalOrders();
            context.Response.Write(new JavaScriptSerializer().Serialize(new Dictionary<string, object> { { "orders", orders } }));
        }
        catch (Exception ex)
        {
            HubRiseIntegration.LogProcess("ERROR", "HubRiseOrdersFeed: " + ex);
            context.Response.StatusCode = 502;
            if (context.Request.QueryString["debug"] == "1")
                context.Response.Write(new JavaScriptSerializer().Serialize(new Dictionary<string, object> { { "error", "feed_failed" }, { "detail", ex.Message } }));
            else
                context.Response.Write("{\"error\":\"feed_failed\"}");
        }
    }

    // Common external_order path. The original HubRise payload is the sole source of items;
    // the legacy hubrise_* projection remains below only as rollback reference.
    private List<object> FetchAndMarkPendingExternalOrders()
    {
        var orderIds = new List<long>();
        var orders = new List<object>();
        using (var connection = HubRiseIntegration.OpenDatabase())
        {
            using (var command = new MySqlCommand(@"
                SELECT id, CAST(order_payload AS CHAR) AS order_payload
                FROM external_order
                WHERE source = 'hubrise' AND imported_at_utc IS NULL
                ORDER BY id ASC LIMIT " + MaxOrdersPerRequest, connection))
            {
                command.CommandTimeout = CommandTimeoutSeconds;
                using (var reader = command.ExecuteReader())
                {
                    while (reader.Read())
                    {
                        orderIds.Add(Convert.ToInt64(reader["id"]));
                        orders.Add(new JavaScriptSerializer().DeserializeObject(reader["order_payload"].ToString()));
                    }
                }
            }

            if (orderIds.Count > 0)
            {
                var placeholders = new List<string>();
                using (var update = connection.CreateCommand())
                {
                    update.CommandTimeout = CommandTimeoutSeconds;
                    for (var i = 0; i < orderIds.Count; i++)
                    {
                        var parameter = "@externalId" + i;
                        placeholders.Add(parameter);
                        update.Parameters.AddWithValue(parameter, orderIds[i]);
                    }
                    update.CommandText = "UPDATE external_order SET imported_at_utc = UTC_TIMESTAMP() WHERE id IN (" + string.Join(",", placeholders) + ")";
                    update.ExecuteNonQuery();
                }
            }
        }
        return orders;
    }

    private List<object> FetchAndMarkPendingOrders()
    {
        var orderIds = new List<long>();
        var orders = new List<object>();

        using (var connection = HubRiseIntegration.OpenDatabase())
        using (var transaction = connection.BeginTransaction())
        {
            try
            {
                using (var command = new MySqlCommand(@"
                    SELECT id, external_order_id, status, service_type, customer_name,
                           total_fractional, currency_code, collection_code, channel, first_received_at_utc
                    FROM hubrise_order
                    WHERE fetched_by_pos_at_utc IS NULL
                    ORDER BY id ASC
                    LIMIT " + MaxOrdersPerRequest, connection, transaction))
                {
                    command.CommandTimeout = CommandTimeoutSeconds;
                    using (var reader = command.ExecuteReader())
                    while (reader.Read())
                    {
                        var id = Convert.ToInt64(reader["id"]);
                        orderIds.Add(id);
                        var totalFractional = reader["total_fractional"] == DBNull.Value ? (long?)null : Convert.ToInt64(reader["total_fractional"]);
                        orders.Add(new Dictionary<string, object>
                        {
                            { "external_order_id", reader["external_order_id"].ToString() },
                            { "status", reader["status"] as string },
                            { "service_type", reader["service_type"] as string },
                            { "customer_name", reader["customer_name"] as string },
                            { "total", totalFractional.HasValue ? (object)(totalFractional.Value / 100.0) : null },
                            { "currency", reader["currency_code"] as string },
                            { "collection_code", reader["collection_code"] as string },
                            { "channel", reader["channel"] as string },
                            { "received_at", Convert.ToDateTime(reader["first_received_at_utc"]).ToString("o") },
                            { "items", new List<object>() }
                        });
                    }
                }

                foreach (var order in orders)
                {
                    var externalOrderId = (string)((Dictionary<string, object>)order)["external_order_id"];
                    ((Dictionary<string, object>)order)["items"] = FetchItems(connection, transaction, externalOrderId);
                }

                if (orderIds.Count > 0)
                {
                    var placeholders = new List<string>();
                    using (var update = connection.CreateCommand())
                    {
                        update.Transaction = transaction;
                        update.CommandTimeout = CommandTimeoutSeconds;
                        for (var i = 0; i < orderIds.Count; i++)
                        {
                            var paramName = "@id" + i;
                            placeholders.Add(paramName);
                            update.Parameters.AddWithValue(paramName, orderIds[i]);
                        }
                        update.CommandText = "UPDATE hubrise_order SET fetched_by_pos_at_utc = UTC_TIMESTAMP() WHERE id IN (" +
                            string.Join(",", placeholders) + ")";
                        update.ExecuteNonQuery();
                    }
                }

                transaction.Commit();
            }
            catch
            {
                transaction.Rollback();
                throw;
            }
        }

        return orders;
    }

    private List<object> FetchItems(MySqlConnection connection, MySqlTransaction transaction, string externalOrderId)
    {
        var items = new List<object>();
        using (var command = new MySqlCommand(@"
            SELECT line_number, item_name, quantity, unit_price_fractional, hubrise_ref
            FROM hubrise_order_item
            WHERE external_order_id = @externalOrderId
            ORDER BY line_number ASC", connection, transaction))
        {
            command.CommandTimeout = CommandTimeoutSeconds;
            command.Parameters.AddWithValue("@externalOrderId", externalOrderId);
            using (var reader = command.ExecuteReader())
            {
                while (reader.Read())
                {
                    var unitPrice = reader["unit_price_fractional"] == DBNull.Value ? (long?)null : Convert.ToInt64(reader["unit_price_fractional"]);
                    items.Add(new Dictionary<string, object>
                    {
                        { "line_number", Convert.ToInt32(reader["line_number"]) },
                        { "name", reader["item_name"] as string },
                        { "quantity", Convert.ToDecimal(reader["quantity"]) },
                        { "unit_price", unitPrice.HasValue ? (object)(unitPrice.Value / 100.0) : null },
                        { "hubrise_ref", reader["hubrise_ref"] as string },
                        { "options", new List<object>() }
                    });
                }
            }
        }

        foreach (Dictionary<string, object> item in items)
        {
            var lineNumber = (int)item["line_number"];
            item["options"] = FetchOptions(connection, transaction, externalOrderId, lineNumber);
        }

        ResolveCategories(connection, transaction, items);

        return items;
    }

    private List<object> FetchOptions(MySqlConnection connection, MySqlTransaction transaction, string externalOrderId, int lineNumber)
    {
        var options = new List<object>();
        using (var command = new MySqlCommand(@"
            SELECT option_name, quantity, price_fractional
            FROM hubrise_order_option
            WHERE external_order_id = @externalOrderId AND line_number = @lineNumber
            ORDER BY option_number ASC", connection, transaction))
        {
            command.CommandTimeout = CommandTimeoutSeconds;
            command.Parameters.AddWithValue("@externalOrderId", externalOrderId);
            command.Parameters.AddWithValue("@lineNumber", lineNumber);
            using (var reader = command.ExecuteReader())
            {
                while (reader.Read())
                {
                    var price = reader["price_fractional"] == DBNull.Value ? (long?)null : Convert.ToInt64(reader["price_fractional"]);
                    options.Add(new Dictionary<string, object>
                    {
                        { "name", reader["option_name"] as string },
                        { "quantity", Convert.ToDecimal(reader["quantity"]) },
                        { "price", price.HasValue ? (object)(price.Value / 100.0) : null }
                    });
                }
            }
        }
        return options;
    }

    // Il ref di ogni SKU caricata con HubRiseCatalogSync.ashx e' "P{id_prodotto_locale}" (vedi
    // quel file): per gli ordini che arrivano dal catalogo reale possiamo risalire alla categoria
    // del prodotto in v2_products/v2_categories e usarla per instradare il piatto sul monitor
    // cucina giusto, esattamente come per un ordine da tavolo. Se il ref non segue quella
    // convenzione (es. ordini di test con cataloghi finti), l'item resta senza categoria: verra'
    // instradato sul monitor di default lato client.
    private void ResolveCategories(MySqlConnection connection, MySqlTransaction transaction, List<object> items)
    {
        var productIds = new List<int>();
        foreach (Dictionary<string, object> item in items)
        {
            var hubriseRef = item["hubrise_ref"] as string;
            var match = hubriseRef != null ? Regex.Match(hubriseRef, "^P(\\d+)$") : null;
            if (match != null && match.Success) productIds.Add(int.Parse(match.Groups[1].Value));
        }
        if (productIds.Count == 0) return;

        var categoryByProductId = new Dictionary<int, string>();
        var placeholders = new List<string>();
        using (var command = connection.CreateCommand())
        {
            command.Transaction = transaction;
            command.CommandTimeout = CommandTimeoutSeconds;
            for (var i = 0; i < productIds.Count; i++)
            {
                var paramName = "@id" + i;
                placeholders.Add(paramName);
                command.Parameters.AddWithValue(paramName, productIds[i]);
            }
            command.CommandText = @"
                SELECT p.id, c.name_en
                FROM v2_products p
                JOIN v2_categories c ON c.id = p.category_id
                WHERE p.id IN (" + string.Join(",", placeholders) + ")";
            using (var reader = command.ExecuteReader())
            {
                while (reader.Read())
                    categoryByProductId[Convert.ToInt32(reader["id"])] = reader["name_en"].ToString();
            }
        }

        foreach (Dictionary<string, object> item in items)
        {
            var hubriseRef = item["hubrise_ref"] as string;
            var match = hubriseRef != null ? Regex.Match(hubriseRef, "^P(\\d+)$") : null;
            var productId = match != null && match.Success ? int.Parse(match.Groups[1].Value) : (int?)null;
            item["category"] = productId.HasValue && categoryByProductId.ContainsKey(productId.Value)
                ? categoryByProductId[productId.Value]
                : null;
        }
    }
}
