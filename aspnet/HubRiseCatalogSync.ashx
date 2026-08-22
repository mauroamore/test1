<%@ WebHandler Language="C#" Class="HubRiseCatalogSync" %>

using System;
using System.Collections.Generic;
using System.Configuration;
using System.Globalization;
using System.IO;
using System.Net;
using System.Text;
using System.Web;
using System.Web.Script.Serialization;
using MySql.Data.MySqlClient;

/// <summary>
/// Sync catalogo verso HubRise, solo su richiesta manuale (mai automatico: un caricamento
/// sbagliato puo' rompere il menu su tutte le piattaforme di delivery collegate). Sorgente dati:
/// v2_categories/v2_products (stessa fonte di MenuService.asmx e DeliverooMenuSync.ashx), filtrata
/// su is_active=1 AND is_delivery=1. Ref code deterministici ("C{id}"/"P{id}"): non serve una
/// tabella di mapping separata, il ref si ricostruisce dall'id locale.
/// Niente SKU multipli/varianti ne' option_list: in questo gestionale i prodotti non hanno prezzi
/// per variante ne' opzioni a pagamento (gli "ingredienti" sono solo informativi), quindi ogni
/// prodotto ha una singola SKU col prezzo di v2_products. Niente immagini in questo giro.
/// </summary>
public class HubRiseCatalogSync : IHttpHandler
{
    public bool IsReusable { get { return false; } }

    public void ProcessRequest(HttpContext context)
    {
        context.Response.ContentType = "application/json";

        var expectedKey = ConfigurationManager.AppSettings["HubRiseCatalogSyncKey"];
        var suppliedKey = context.Request.QueryString["key"];
        if (string.IsNullOrEmpty(expectedKey) || !string.Equals(expectedKey, suppliedKey, StringComparison.Ordinal))
        {
            context.Response.StatusCode = 401;
            context.Response.Write("{\"error\":\"Unauthorized\"}");
            return;
        }

        try
        {
            var catalogData = BuildCatalogData();
            if (string.Equals(context.Request.QueryString["mode"], "upload", StringComparison.OrdinalIgnoreCase))
            {
                UploadCatalog(context, catalogData);
            }
            else
            {
                context.Response.Write(new JavaScriptSerializer().Serialize(catalogData));
            }
        }
        catch (WebException ex)
        {
            var response = ex.Response as HttpWebResponse;
            var detail = "";
            if (response != null)
            {
                using (var reader = new StreamReader(response.GetResponseStream())) detail = reader.ReadToEnd();
            }
            HubRiseIntegration.LogProcess("ERROR", "HubRiseCatalogSync: " + ex.Message + " " + detail);
            context.Response.StatusCode = 502;
            context.Response.Write("{\"ok\":false,\"error\":\"hubrise_catalog_upload_failed\",\"detail\":" +
                (string.IsNullOrWhiteSpace(detail) ? "null" : new JavaScriptSerializer().Serialize(detail)) + "}");
        }
        catch (Exception ex)
        {
            HubRiseIntegration.LogProcess("ERROR", "HubRiseCatalogSync: " + ex);
            context.Response.StatusCode = 500;
            context.Response.Write("{\"error\":\"catalog_sync_failed\"}");
        }
    }

    private Dictionary<string, object> BuildCatalogData()
    {
        var categories = new List<Dictionary<string, object>>();
        var productsByCategory = new Dictionary<int, List<Dictionary<string, object>>>();

        using (var connection = HubRiseIntegration.OpenDatabase())
        {
            using (var command = new MySqlCommand(
                "SELECT id, name_en FROM v2_categories ORDER BY sort_order, id", connection))
            using (var reader = command.ExecuteReader())
            {
                while (reader.Read())
                {
                    categories.Add(new Dictionary<string, object>
                    {
                        { "id", Convert.ToInt32(reader["id"]) },
                        { "name", reader["name_en"].ToString() }
                    });
                }
            }

            using (var command = new MySqlCommand(
                "SELECT id, category_id, name, price FROM v2_products WHERE is_active = 1 AND is_delivery = 1 ORDER BY category_id, id",
                connection))
            using (var reader = command.ExecuteReader())
            {
                while (reader.Read())
                {
                    var categoryId = Convert.ToInt32(reader["category_id"]);
                    var productId = Convert.ToInt32(reader["id"]);
                    var priceText = Convert.ToDecimal(reader["price"]).ToString("0.00", CultureInfo.InvariantCulture) + " EUR";

                    var product = new Dictionary<string, object>
                    {
                        { "ref", "P" + productId },
                        { "category_ref", "C" + categoryId },
                        { "name", reader["name"].ToString() },
                        { "skus", new List<object>
                            {
                                new Dictionary<string, object>
                                {
                                    { "ref", "P" + productId },
                                    { "price", priceText }
                                }
                            }
                        }
                    };

                    if (!productsByCategory.ContainsKey(categoryId))
                        productsByCategory[categoryId] = new List<Dictionary<string, object>>();
                    productsByCategory[categoryId].Add(product);
                }
            }
        }

        var categoryList = new List<object>();
        var productList = new List<object>();
        foreach (var category in categories)
        {
            var categoryId = (int)category["id"];
            if (!productsByCategory.ContainsKey(categoryId)) continue; // salta categorie senza prodotti delivery attivi
            categoryList.Add(new Dictionary<string, object>
            {
                { "ref", "C" + categoryId },
                { "name", category["name"] }
            });
            productList.AddRange(productsByCategory[categoryId]);
        }

        return new Dictionary<string, object>
        {
            { "name", "Thai Princess - menu delivery" },
            { "data", new Dictionary<string, object>
                {
                    { "categories", categoryList },
                    { "products", productList }
                }
            }
        };
    }

    private void UploadCatalog(HttpContext context, Dictionary<string, object> catalogData)
    {
        var connectionInfo = HubRiseIntegration.GetConnection();
        if (string.IsNullOrEmpty(connectionInfo.CatalogId))
        {
            context.Response.StatusCode = 500;
            context.Response.Write("{\"error\":\"Nessun catalog_id associato alla connessione HubRise\"}");
            return;
        }

        var url = HubRiseIntegration.ApiBaseUrl + "/catalogs/" + HttpUtility.UrlEncode(connectionInfo.CatalogId);
        var request = HubRiseIntegration.CreateApiRequest(url, "PUT");
        var payload = new JavaScriptSerializer().Serialize(catalogData);
        var bytes = Encoding.UTF8.GetBytes(payload);
        request.ContentLength = bytes.Length;
        using (var stream = request.GetRequestStream()) stream.Write(bytes, 0, bytes.Length);

        using (var response = (HttpWebResponse)request.GetResponse())
        using (var reader = new StreamReader(response.GetResponseStream()))
        {
            var responseBody = reader.ReadToEnd();
            var productCount = ((List<object>)((Dictionary<string, object>)catalogData["data"])["products"]).Count;
            HubRiseIntegration.LogProcess("INFO", "HubRiseCatalogSync: catalogo caricato, " + productCount + " prodotti.");
            context.Response.Write("{\"ok\":true,\"hubrise_response\":" +
                (string.IsNullOrWhiteSpace(responseBody) ? "null" : responseBody) + "}");
        }
    }
}
