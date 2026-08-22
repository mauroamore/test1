<%@ WebService Language="C#" Class="MenuService" %>

using System;
using System.Collections.Generic;
using System.Configuration;
using System.Web.Script.Serialization;
using System.Web.Services;
using MySql.Data.MySqlClient;

[WebService(Namespace = "http://tempuri.org/")]
[WebServiceBinding(ConformsTo = WsiProfiles.BasicProfile1_1)]
public class MenuService : WebService
{
    private string ConnectionString
    {
        get { return ConfigurationManager.ConnectionStrings["MySqlConnectionString"].ConnectionString; }
    }

    [WebMethod]
    public string GetMenu()
    {
        // Il gestionale gira su un'origine diversa dal sito del servizio.
        Context.Response.Headers["Access-Control-Allow-Origin"] = "*";
        Context.Response.Headers["Access-Control-Allow-Methods"] = "GET, OPTIONS";
        Context.Response.Headers["Access-Control-Allow-Headers"] = "Content-Type";

        var categories = new List<Dictionary<string, object>>();
        var byId = new Dictionary<int, Dictionary<string, object>>();
        var ingredientMap = new Dictionary<int, List<string>>();

        using (var connection = new MySqlConnection(ConnectionString))
        {
            connection.Open();
            using (var command = new MySqlCommand("SELECT id, name_en FROM v2_categories ORDER BY sort_order, id", connection))
            using (var reader = command.ExecuteReader())
            {
                while (reader.Read())
                {
                    var category = new Dictionary<string, object>();
                    category.Add("id", Convert.ToInt32(reader["id"]));
                    category.Add("name", reader["name_en"].ToString());
                    category.Add("items", new List<object>());
                    categories.Add(category);
                    byId[(int)category["id"]] = category;
                }
            }

            using (var command = new MySqlCommand("SELECT pi.product_id, i.name_en FROM v2_product_ingredients pi JOIN v2_ingredients i ON pi.ingredient_id = i.id", connection))
            using (var reader = command.ExecuteReader())
            {
                while (reader.Read())
                {
                    var productId = Convert.ToInt32(reader["product_id"]);
                    if (!ingredientMap.ContainsKey(productId)) ingredientMap[productId] = new List<string>();
                    ingredientMap[productId].Add(reader["name_en"].ToString());
                }
            }

            using (var command = new MySqlCommand("SELECT id, category_id, name, description_en, description_it, image_url, is_delivery, price, spiciness_level FROM v2_products WHERE is_active = 1 ORDER BY category_id, id", connection))
            using (var reader = command.ExecuteReader())
            {
                while (reader.Read())
                {
                    var categoryId = Convert.ToInt32(reader["category_id"]);
                    if (!byId.ContainsKey(categoryId)) continue;
                    var item = new Dictionary<string, object>();
                    item.Add("id", Convert.ToInt32(reader["id"]));
                    item.Add("name", reader["name"].ToString());
                    item.Add("eng", reader["description_en"] == DBNull.Value ? "" : reader["description_en"].ToString());
                    item.Add("it", reader["description_it"] == DBNull.Value ? "" : reader["description_it"].ToString());
                    item.Add("image", reader["image_url"] == DBNull.Value ? "" : reader["image_url"].ToString());
                    item.Add("is_delivery", reader["is_delivery"] == DBNull.Value || Convert.ToBoolean(reader["is_delivery"]));
                    item.Add("ingredients", ingredientMap.ContainsKey(Convert.ToInt32(reader["id"])) ? ingredientMap[Convert.ToInt32(reader["id"])] : new List<string>());
                    item.Add("price", Convert.ToDecimal(reader["price"]));
                    item.Add("spiciness", reader["spiciness_level"] == DBNull.Value ? 0 : Convert.ToInt32(reader["spiciness_level"]));
                    ((List<object>)byId[categoryId]["items"]).Add(item);
                }
            }
        }

        return new JavaScriptSerializer().Serialize(categories);
    }
}
