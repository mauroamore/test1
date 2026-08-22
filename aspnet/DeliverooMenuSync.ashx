<%@ WebHandler Language="C#" Class="DeliverooMenuSync" %>

using System;
using System.Collections.Generic;
using System.Configuration;
using System.IO;
using System.Net;
using System.Text;
using System.Web;
using System.Web.Script.Serialization;
using MySql.Data.MySqlClient;

public class DeliverooMenuSync : IHttpHandler
{
    public bool IsReusable { get { return false; } }

    public void ProcessRequest(HttpContext context)
    {
        context.Response.ContentType = "application/json; charset=utf-8";
        try
        {
            var mode = (context.Request.QueryString["mode"] ?? "preview").ToLowerInvariant();
            if (mode == "brand")
            {
                context.Response.Write(GetSiteBrandId(context.Request.QueryString["site_id"]));
                return;
            }

            if (mode == "unavailability")
            {
                var availabilityKey = ConfigurationManager.AppSettings["DeliverooMenuSyncKey"];
                if (string.IsNullOrEmpty(availabilityKey) || !string.Equals(context.Request.QueryString["key"], availabilityKey, StringComparison.Ordinal))
                {
                    context.Response.StatusCode = 403;
                    context.Response.Write("{\"error\":\"upload not authorized\"}");
                    return;
                }
                context.Response.Write(UpdateUnavailability(context.Request.QueryString["menu_id"], context.Request.QueryString["step"]));
                return;
            }

            if (mode == "replace-unavailability")
            {
                var replaceKey = ConfigurationManager.AppSettings["DeliverooMenuSyncKey"];
                if (string.IsNullOrEmpty(replaceKey) || !string.Equals(context.Request.QueryString["key"], replaceKey, StringComparison.Ordinal))
                {
                    context.Response.StatusCode = 403;
                    context.Response.Write("{\"error\":\"upload not authorized\"}");
                    return;
                }
                context.Response.Write(ReplaceUnavailability(context.Request.QueryString["menu_id"]));
                return;
            }

            var payload = BuildPayload();
            EnsureSandboxItemCount((Dictionary<string, object>)payload, context.Request.QueryString["menu_id"]);
            AddSandboxRevision((Dictionary<string, object>)payload, context.Request.QueryString["menu_id"]);
            if (mode == "get")
            {
                context.Response.Write(GetUploadedMenu());
                return;
            }
            if (mode != "upload")
            {
                context.Response.Write(new JavaScriptSerializer().Serialize(payload));
                return;
            }

            var syncKey = ConfigurationManager.AppSettings["DeliverooMenuSyncKey"];
            if (string.IsNullOrEmpty(syncKey) || !string.Equals(context.Request.QueryString["key"], syncKey, StringComparison.Ordinal))
            {
                context.Response.StatusCode = 403;
                context.Response.Write("{\"error\":\"upload not authorized\"}");
                return;
            }

            var response = Upload(new JavaScriptSerializer().Serialize(payload), context.Request.QueryString["menu_id"]);
            context.Response.Write(response);
        }
        catch (Exception ex)
        {
            context.Response.StatusCode = 500;
            context.Response.Write(new JavaScriptSerializer().Serialize(new { error = ex.Message }));
        }
    }

    private string GetSiteBrandId(string siteId)
    {
        if (string.IsNullOrEmpty(siteId)) throw new ArgumentException("site_id obbligatorio");
        var token = GetToken();
        var url = "https://api-sandbox.developers.deliveroo.com/site/v1/restaurant_locations/" + HttpUtility.UrlEncode(siteId);
        var request = (HttpWebRequest)WebRequest.Create(url);
        request.Method = "GET";
        request.Headers["Authorization"] = "Bearer " + token;
        try
        {
            using (var response = (HttpWebResponse)request.GetResponse())
            using (var reader = new StreamReader(response.GetResponseStream()))
                return reader.ReadToEnd();
        }
        catch (WebException ex)
        {
            var http = ex.Response as HttpWebResponse;
            var detail = "";
            if (http != null)
                using (var reader = new StreamReader(http.GetResponseStream())) detail = reader.ReadToEnd();
            return new JavaScriptSerializer().Serialize(new { ok = false, status = http == null ? 0 : (int)http.StatusCode, response = detail, url = url });
        }
    }

    private string UpdateUnavailability(string menuId, string step)
    {
        if (string.IsNullOrEmpty(menuId)) throw new ArgumentException("menu_id obbligatorio");
        var updates = new List<object>();
        if (step == "1")
        {
            updates.Add(new Dictionary<string, object> { { "item_id", "orange_juice" }, { "status", "unavailable" } });
            updates.Add(new Dictionary<string, object> { { "item_id", "granola" }, { "status", "unavailable" } });
        }
        else if (step == "2")
        {
            updates.Add(new Dictionary<string, object> { { "item_id", "orange_juice" }, { "status", "available" } });
            updates.Add(new Dictionary<string, object> { { "item_id", "whole_milk" }, { "status", "unavailable" } });
        }
        else throw new ArgumentException("step deve essere 1 o 2");

        var body = new JavaScriptSerializer().Serialize(new Dictionary<string, object> { { "item_unavailabilities", updates } });
        var url = "https://api-sandbox.developers.deliveroo.com/menu/v1/brands/" + ConfigurationManager.AppSettings["DeliverooBrandId"] + "/menus/" + HttpUtility.UrlEncode(menuId) + "/item_unavailabilities/" + ConfigurationManager.AppSettings["DeliverooSiteId"];
        var request = (HttpWebRequest)WebRequest.Create(url);
        request.Method = "POST";
        request.ContentType = "application/json";
        request.Headers["Authorization"] = "Bearer " + GetToken();
        var bytes = Encoding.UTF8.GetBytes(body);
        using (var stream = request.GetRequestStream()) stream.Write(bytes, 0, bytes.Length);
        try
        {
            using (var response = (HttpWebResponse)request.GetResponse())
            using (var reader = new StreamReader(response.GetResponseStream()))
                return new JavaScriptSerializer().Serialize(new { ok = true, status = (int)response.StatusCode, response = reader.ReadToEnd(), step = step });
        }
        catch (WebException ex)
        {
            var http = ex.Response as HttpWebResponse;
            var detail = "";
            if (http != null)
                using (var reader = new StreamReader(http.GetResponseStream())) detail = reader.ReadToEnd();
            return new JavaScriptSerializer().Serialize(new { ok = false, status = http == null ? 0 : (int)http.StatusCode, response = detail, step = step, url = url });
        }
    }

    private string ReplaceUnavailability(string menuId)
    {
        if (string.IsNullOrEmpty(menuId)) throw new ArgumentException("menu_id obbligatorio");
        var baseUrl = "https://api-sandbox.developers.deliveroo.com/menu/v1/brands/" + ConfigurationManager.AppSettings["DeliverooBrandId"] + "/menus/" + HttpUtility.UrlEncode(menuId) + "/item_unavailabilities/" + ConfigurationManager.AppSettings["DeliverooSiteId"];
        var getRequest = (HttpWebRequest)WebRequest.Create(baseUrl);
        getRequest.Method = "GET";
        getRequest.Headers["Authorization"] = "Bearer " + GetToken();
        string current;
        using (var getResponse = (HttpWebResponse)getRequest.GetResponse())
        using (var getReader = new StreamReader(getResponse.GetResponseStream())) current = getReader.ReadToEnd();

        var state = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(current);
        var unavailable = state.ContainsKey("unavailable_ids") ? state["unavailable_ids"] as System.Collections.ArrayList : new System.Collections.ArrayList();
        if (!unavailable.Contains("whole_milk")) unavailable.Add("whole_milk");
        state["unavailable_ids"] = unavailable;
        var body = new JavaScriptSerializer().Serialize(state);
        var putRequest = (HttpWebRequest)WebRequest.Create(baseUrl);
        putRequest.Method = "PUT";
        putRequest.ContentType = "application/json";
        putRequest.Headers["Authorization"] = "Bearer " + GetToken();
        var bytes = Encoding.UTF8.GetBytes(body);
        using (var stream = putRequest.GetRequestStream()) stream.Write(bytes, 0, bytes.Length);
        using (var putResponse = (HttpWebResponse)putRequest.GetResponse())
        using (var putReader = new StreamReader(putResponse.GetResponseStream()))
            return new JavaScriptSerializer().Serialize(new { ok = true, status = (int)putResponse.StatusCode, get = current, put = putReader.ReadToEnd() });
    }

    private object BuildPayload()
    {
        var categories = new List<object>();
        var items = new List<object>();
        var modifiers = new List<object>();
        var itemIdsByCategory = new Dictionary<int, List<string>>();
        var ingredientNames = new Dictionary<int, string>();
        var productIngredients = new Dictionary<int, List<int>>();
        var firstItemId = "";
        var standaloneProductIds = new List<string>();
        var standalonePrices = new Dictionary<string, long>();
        var cs = ConfigurationManager.ConnectionStrings["MySqlConnectionString"].ConnectionString;
        using (var cn = new MySqlConnection(cs))
        {
            cn.Open();
            using (var cmd = new MySqlCommand("SELECT id, name_en FROM v2_ingredients ORDER BY id", cn))
            using (var r = cmd.ExecuteReader())
                while (r.Read()) ingredientNames[Convert.ToInt32(r["id"])] = Convert.ToString(r["name_en"]);

            using (var cmd = new MySqlCommand("SELECT product_id, ingredient_id FROM v2_product_ingredients ORDER BY product_id, ingredient_id", cn))
            using (var r = cmd.ExecuteReader())
                while (r.Read())
                {
                    var productId = Convert.ToInt32(r["product_id"]);
                    if (!productIngredients.ContainsKey(productId)) productIngredients[productId] = new List<int>();
                    productIngredients[productId].Add(Convert.ToInt32(r["ingredient_id"]));
                }

            using (var cmd = new MySqlCommand("SELECT id, name_en FROM v2_categories ORDER BY sort_order, id", cn))
            using (var r = cmd.ExecuteReader())
                while (r.Read())
                {
                    var id = Convert.ToInt32(r["id"]);
                    var deliverooId = "cat-" + id;
                    itemIdsByCategory[id] = new List<string>();
                    categories.Add(new Dictionary<string, object> {
                        { "id", deliverooId },
                        { "name", new Dictionary<string, string> { { "en", Convert.ToString(r["name_en"]) } } },
                        { "description", new Dictionary<string, string>() },
                        { "item_ids", itemIdsByCategory[id] }
                    });
                }

            using (var cmd = new MySqlCommand("SELECT id, category_id, name, description_en, price FROM v2_products WHERE is_active = 1 AND is_delivery = 1 ORDER BY category_id, id", cn))
            using (var r = cmd.ExecuteReader())
                while (r.Read())
                {
                    var id = Convert.ToInt32(r["id"]);
                    var categoryId = Convert.ToInt32(r["category_id"]);
                    if (!itemIdsByCategory.ContainsKey(categoryId)) continue;
                    var itemId = "item-" + id;
                    if (firstItemId == "") firstItemId = itemId;
                    standaloneProductIds.Add(itemId);
                    standalonePrices[itemId] = Convert.ToInt64(Math.Round(Convert.ToDecimal(r["price"]) * 100m));
                    itemIdsByCategory[categoryId].Add(itemId);
                    var modifierIds = new List<string>();
                    if (productIngredients.ContainsKey(id) && productIngredients[id].Count > 0) modifierIds.Add("mod-" + id);
                    items.Add(new Dictionary<string, object> {
                        { "id", itemId },
                        { "name", new Dictionary<string, string> { { "en", Convert.ToString(r["name"]) } } },
                        { "description", new Dictionary<string, string> { { "en", r["description_en"] == DBNull.Value || string.IsNullOrWhiteSpace(Convert.ToString(r["description_en"])) ? Convert.ToString(r["name"]) : Convert.ToString(r["description_en"]) } } },
                        { "operational_name", Convert.ToString(r["name"]) },
                        { "plu", "MU" + id },
                        { "image", new Dictionary<string, string> { { "url", ConfigurationManager.AppSettings["DeliverooMenuImageUrl"] ?? "https://thaiprincess.it/Content/menu-cover.jpg" } } },
                        { "price_info", new Dictionary<string, object> { { "price", Convert.ToInt64(Math.Round(Convert.ToDecimal(r["price"]) * 100m)) }, { "currency_code", "EUR" }, { "overrides", new List<object>() }, { "fees", new List<object>() } } },
                        { "tax_rate", "10" },
                        { "contains_alcohol", false },
                        { "modifier_ids", modifierIds },
                        { "diets", new List<string> { id % 2 == 0 ? "vegetarian" : "vegan" } },
                        { "type", "ITEM" },
                        { "external_data", "local_product_id=" + id }
                    });
                }
        }

        // Deliveroo rich-menu validation: one item must belong to two categories.
        if (firstItemId != "" && itemIdsByCategory.Count > 1)
        {
            var categoryIds = new List<int>(itemIdsByCategory.Keys);
            if (!itemIdsByCategory[categoryIds[1]].Contains(firstItemId))
                itemIdsByCategory[categoryIds[1]].Add(firstItemId);
        }

        // Sandbox bundle validation: create two real bundles from two standalone items.
        var bundleCandidates = standaloneProductIds.FindAll(delegate(string id) { return standalonePrices[id] > 0; });
        if (bundleCandidates.Count >= 2 && itemIdsByCategory.Count >= 2)
        {
            var bundleItemA = bundleCandidates[0];
            var bundleItemB = bundleCandidates[0];
            foreach (var candidate in bundleCandidates)
            {
                if (standalonePrices[candidate] < standalonePrices[bundleItemA]) bundleItemA = candidate;
                if (standalonePrices[candidate] > standalonePrices[bundleItemB]) bundleItemB = candidate;
            }
            if (bundleItemA == bundleItemB) bundleItemB = bundleCandidates[1];
            var cheapest = standalonePrices[bundleItemA];
            cheapest = standalonePrices[bundleItemA];
            var bundleBasePrice = cheapest * 2;
            var bundleChoices = new List<string> { bundleItemA, bundleItemB };
            var bundleModifierIds = new List<string> { "sandbox-bundle-section-1", "sandbox-bundle-section-2" };
            modifiers.Add(new Dictionary<string, object> {
                { "id", "sandbox-bundle-section-1" },
                { "name", new Dictionary<string, string> { { "en", "Choose your first item" } } },
                { "description", new Dictionary<string, string> { { "en", "Select one item for the bundle" } } },
                { "item_ids", bundleChoices },
                { "min_selection", 1 },
                { "max_selection", 1 },
                { "repeatable", false },
                { "type", "bundle-item" }
            });
            modifiers.Add(new Dictionary<string, object> {
                { "id", "sandbox-bundle-section-2" },
                { "name", new Dictionary<string, string> { { "en", "Choose your second item" } } },
                { "description", new Dictionary<string, string> { { "en", "Select one additional item for the bundle" } } },
                { "item_ids", bundleChoices },
                { "min_selection", 1 },
                { "max_selection", 1 },
                { "repeatable", false },
                { "type", "bundle-item" }
            });

            foreach (var productId in bundleChoices)
            {
                var product = items.Find(delegate(object value)
                {
                    var item = value as Dictionary<string, object>;
                    return item != null && Convert.ToString(item["id"]) == productId;
                }) as Dictionary<string, object>;
                if (product != null)
                {
                    var priceInfo = product["price_info"] as Dictionary<string, object>;
                    if (Convert.ToInt64(priceInfo["price"]) <= 0)
                        priceInfo["price"] = 100L;
                    var overrides = priceInfo["overrides"] as List<object>;
                    var bundleItemOverride = productId == bundleItemB ? standalonePrices[bundleItemB] - cheapest : 0;
                    overrides.Add(new Dictionary<string, object> { { "id", "sandbox-bundle-1" }, { "price", bundleItemOverride }, { "type", "ITEM" } });
                    overrides.Add(new Dictionary<string, object> { { "id", "sandbox-bundle-2" }, { "price", bundleItemOverride }, { "type", "ITEM" } });
                    if (productId != bundleItemB)
                    {
                        overrides.Add(new Dictionary<string, object> { { "id", "sandbox-bundle-section-1" }, { "price", 0 }, { "type", "MODIFIER" } });
                        overrides.Add(new Dictionary<string, object> { { "id", "sandbox-bundle-section-2" }, { "price", 0 }, { "type", "MODIFIER" } });
                    }
                }
            }

            items.Add(new Dictionary<string, object> {
                { "id", "sandbox-bundle-1" },
                { "name", new Dictionary<string, string> { { "en", "Sandbox Meal Bundle" } } },
                { "description", new Dictionary<string, string> { { "en", "A test bundle with two selectable items" } } },
                { "operational_name", "Sandbox Meal Bundle" },
                { "plu", "BUNDLE1" },
                { "price_info", new Dictionary<string, object> { { "price", bundleBasePrice }, { "currency_code", "EUR" }, { "overrides", new List<object>() }, { "fees", new List<object>() } } },
                { "tax_rate", "10" },
                { "contains_alcohol", false },
                { "modifier_ids", bundleModifierIds },
                { "type", "BUNDLE" },
                { "party_size", 1 }
            });
            items.Add(new Dictionary<string, object> {
                { "id", "sandbox-bundle-2" },
                { "name", new Dictionary<string, string> { { "en", "Sandbox Dinner Bundle" } } },
                { "description", new Dictionary<string, string> { { "en", "A second test bundle with two selectable items" } } },
                { "operational_name", "Sandbox Dinner Bundle" },
                { "plu", "BUNDLE2" },
                { "price_info", new Dictionary<string, object> { { "price", bundleBasePrice }, { "currency_code", "EUR" }, { "overrides", new List<object>() }, { "fees", new List<object>() } } },
                { "tax_rate", "10" },
                { "contains_alcohol", false },
                { "modifier_ids", bundleModifierIds },
                { "type", "BUNDLE" }
            });
            var categoryKeys = new List<int>(itemIdsByCategory.Keys);
            itemIdsByCategory[categoryKeys[0]].Add("sandbox-bundle-1");
            itemIdsByCategory[categoryKeys[1]].Add("sandbox-bundle-2");
        }

        // Gli ingredienti sono pubblicati come scelte a prezzo zero e collegati
        // a ciascun piatto tramite un gruppo di modificatori.
        foreach (var ingredient in ingredientNames)
        {
            items.Add(new Dictionary<string, object> {
                { "id", "ingredient-" + ingredient.Key },
                { "name", new Dictionary<string, string> { { "en", ingredient.Value } } },
                { "description", new Dictionary<string, string> { { "en", "Ingredient option: " + ingredient.Value } } },
                { "operational_name", ingredient.Value },
                { "plu", "OM" + ingredient.Key },
                { "price_info", new Dictionary<string, object> { { "price", 0 }, { "currency_code", "EUR" }, { "overrides", new List<object>() }, { "fees", new List<object>() } } },
                { "tax_rate", "10" },
                { "contains_alcohol", false },
                { "modifier_ids", new List<string>() },
                { "type", "CHOICE" },
                { "external_data", "local_ingredient_id=" + ingredient.Key }
            });
        }
        foreach (var product in productIngredients)
        {
            var choices = new List<string>();
            foreach (var ingredientId in product.Value) choices.Add("ingredient-" + ingredientId);
            modifiers.Add(new Dictionary<string, object> {
                { "id", "mod-" + product.Key },
                { "name", new Dictionary<string, string> { { "en", "Ingredients" } } },
                { "description", new Dictionary<string, string> { { "en", "" } } },
                { "item_ids", choices },
                { "min_selection", 0 },
                { "max_selection", choices.Count },
                { "repeatable", false },
                { "type", "add-ingredient" }
            });
        }

        // Sandbox validation requires one single-select and one multi-select group,
        // each with at least two choices. Reuse the first two real ingredients.
        var testIngredientIds = new List<int>(ingredientNames.Keys);
        if (testIngredientIds.Count >= 2 && firstItemId != "")
        {
            var singleChoices = new List<string> { "ingredient-" + testIngredientIds[0], "ingredient-" + testIngredientIds[1] };
            var multiChoices = new List<string> { "ingredient-" + testIngredientIds[0], "ingredient-" + testIngredientIds[1] };
            modifiers.Add(new Dictionary<string, object> {
                { "id", "sandbox-single-select" },
                { "name", new Dictionary<string, string> { { "en", "Choose one" } } },
                { "description", new Dictionary<string, string> { { "en", "Choose one ingredient" } } },
                { "item_ids", singleChoices },
                { "min_selection", 1 },
                { "max_selection", 1 },
                { "repeatable", false },
                { "type", "product-variation" }
            });
            modifiers.Add(new Dictionary<string, object> {
                { "id", "sandbox-multi-select" },
                { "name", new Dictionary<string, string> { { "en", "Choose extras" } } },
                { "description", new Dictionary<string, string> { { "en", "Choose one or more ingredients" } } },
                { "item_ids", multiChoices },
                { "min_selection", 0 },
                { "max_selection", 2 },
                { "repeatable", false },
                { "type", "add-ingredient" }
            });
            var firstItem = items[0] as Dictionary<string, object>;
            var firstModifierIds = firstItem["modifier_ids"] as List<string>;
            firstModifierIds.Add("sandbox-single-select");
            firstModifierIds.Add("sandbox-multi-select");
        }

        var menu = new Dictionary<string, object>();
        menu.Add("currency_code", "EUR");
        menu.Add("categories", categories);
        menu.Add("items", items);
        menu.Add("modifiers", modifiers);
        menu.Add("mealtimes", new List<object> {
            new Dictionary<string, object> {
                { "id", "all-day" },
                { "name", new Dictionary<string, string> { { "en", "Menu" } } },
                { "description", new Dictionary<string, string> { { "en", "Our menu" } } },
                { "image", new Dictionary<string, string> { { "url", ConfigurationManager.AppSettings["DeliverooMenuImageUrl"] ?? "https://thaiprincess.it/Content/menu-cover.jpg" } } },
                { "category_ids", new List<string>(itemIdsByCategory.Keys.Count) },
                { "schedule", EveryDayRange("00:00", "13:59") }
            },
            new Dictionary<string, object> {
                { "id", "evening" },
                { "name", new Dictionary<string, string> { { "en", "Evening menu" } } },
                { "description", new Dictionary<string, string> { { "en", "Our evening selection" } } },
                { "image", new Dictionary<string, string> { { "url", ConfigurationManager.AppSettings["DeliverooMenuImageUrl"] ?? "https://thaiprincess.it/Content/menu-cover.jpg" } } },
                { "category_ids", new List<string>(itemIdsByCategory.Keys.Count) },
                { "schedule", EveryDayRange("14:00", "23:59") }
            }
        });
        var allCategoryIds = (List<string>)((Dictionary<string, object>)((List<object>)menu["mealtimes"])[0])["category_ids"];
        var eveningCategoryIds = (List<string>)((Dictionary<string, object>)((List<object>)menu["mealtimes"])[1])["category_ids"];
        foreach (var key in itemIdsByCategory.Keys)
        {
            allCategoryIds.Add("cat-" + key);
            eveningCategoryIds.Add("cat-" + key);
        }

        return new Dictionary<string, object> {
            { "name", ConfigurationManager.AppSettings["DeliverooMenuName"] ?? "Thai Princess Menu" },
            { "menu", menu },
            { "site_ids", new List<string> { ConfigurationManager.AppSettings["DeliverooSiteId"] ?? "101" } }
        };
    }

    private void EnsureSandboxItemCount(Dictionary<string, object> payload, string menuId)
    {
        if (string.IsNullOrEmpty(menuId) || !menuId.StartsWith("thai-princess-upload-test-", StringComparison.OrdinalIgnoreCase)) return;
        var menu = payload["menu"] as Dictionary<string, object>;
        if (menu == null) return;
        var items = menu["items"] as List<object>;
        var categories = menu["categories"] as List<object>;
        if (items == null || categories == null || categories.Count == 0) return;
        var itemCount = 0;
        foreach (var value in items)
        {
            var item = value as Dictionary<string, object>;
            if (item != null && Convert.ToString(item["type"]) == "ITEM") itemCount++;
        }
        var firstCategory = categories[0] as Dictionary<string, object>;
        var categoryItems = firstCategory == null ? null : firstCategory["item_ids"] as List<string>;
        if (categoryItems == null) return;
        for (var i = itemCount; i < 100; i++)
        {
            var id = "scenario-item-" + (i + 1).ToString("000");
            items.Add(new Dictionary<string, object> {
                { "id", id },
                { "name", new Dictionary<string, string> { { "en", "Scenario Item " + (i + 1) } } },
                { "description", new Dictionary<string, string> { { "en", "Test menu item" } } },
                { "operational_name", "Scenario Item " + (i + 1) },
                { "plu", "SC" + (i + 1).ToString("000") },
                { "price_info", new Dictionary<string, object> { { "price", 100L }, { "currency_code", "EUR" }, { "overrides", new List<object>() }, { "fees", new List<object>() } } },
                { "tax_rate", "10" },
                { "contains_alcohol", false },
                { "modifier_ids", new List<string>() },
                { "diets", new List<string>() },
                { "type", "ITEM" },
                { "external_data", "sandbox_scenario_item=" + (i + 1) }
            });
            categoryItems.Add(id);
        }
    }

    private void AddSandboxRevision(Dictionary<string, object> payload, string menuId)
    {
        if (string.IsNullOrEmpty(menuId) || !menuId.StartsWith("thai-princess-upload-test-", StringComparison.OrdinalIgnoreCase)) return;
        payload["name"] = "Thai Princess Menu V3 " + DateTime.UtcNow.ToString("yyyyMMddHHmmss");

        var menu = payload["menu"] as Dictionary<string, object>;
        var items = menu == null ? null : menu["items"] as List<object>;
        var firstItem = items == null || items.Count == 0 ? null : items[0] as Dictionary<string, object>;
        var description = firstItem == null ? null : firstItem["description"] as Dictionary<string, string>;
        if (description != null)
            description["en"] = description["en"] + " (V3 sandbox revision " + DateTime.UtcNow.ToString("yyyyMMddHHmmss") + ")";
    }

    private List<object> EveryDay()
    {
        var result = new List<object>();
        for (var day = 0; day < 7; day++) result.Add(new Dictionary<string, object> { { "day_of_week", day }, { "time_periods", new List<object> { new Dictionary<string, string> { { "start", "00:00" }, { "end", "23:59" } } } } });
        return result;
    }

    private List<object> EveryDayRange(string start, string end)
    {
        var result = new List<object>();
        for (var day = 0; day < 7; day++) result.Add(new Dictionary<string, object> { { "day_of_week", day }, { "time_periods", new List<object> { new Dictionary<string, string> { { "start", start }, { "end", end } } } } });
        return result;
    }

    private string Upload(string json, string requestedMenuId)
    {
        var token = GetToken();
        var brand = ConfigurationManager.AppSettings["DeliverooBrandId"];
        var menuId = string.IsNullOrEmpty(requestedMenuId) ? ConfigurationManager.AppSettings["DeliverooMenuId"] : requestedMenuId;
        if (string.IsNullOrEmpty(token) || string.IsNullOrEmpty(brand) || string.IsNullOrEmpty(menuId)) throw new InvalidOperationException("Configura DeliverooClientId, DeliverooClientSecret, DeliverooBrandId e DeliverooMenuId");
        var url = "https://api-sandbox.developers.deliveroo.com/menu/v1/brands/" + HttpUtility.UrlEncode(brand) + "/menus/" + HttpUtility.UrlEncode(menuId);
        var request = (HttpWebRequest)WebRequest.Create(url);
        request.Method = "PUT"; request.ContentType = "application/json"; request.Headers["Authorization"] = "Bearer " + token;
        var bytes = Encoding.UTF8.GetBytes(json); request.ContentLength = bytes.Length;
        using (var stream = request.GetRequestStream()) stream.Write(bytes, 0, bytes.Length);
        try
        {
            using (var response = (HttpWebResponse)request.GetResponse())
            using (var reader = new StreamReader(response.GetResponseStream()))
                return new JavaScriptSerializer().Serialize(new { ok = true, status = (int)response.StatusCode, response = reader.ReadToEnd(), url = url });
        }
        catch (WebException ex)
        {
            var http = ex.Response as HttpWebResponse;
            var detail = "";
            if (http != null)
                using (var reader = new StreamReader(http.GetResponseStream())) detail = reader.ReadToEnd();
            return new JavaScriptSerializer().Serialize(new { ok = false, status = http == null ? 0 : (int)http.StatusCode, response = detail, url = url });
        }
    }

    private string GetUploadedMenu()
    {
        var token = GetToken();
        var brand = ConfigurationManager.AppSettings["DeliverooBrandId"];
        var menuId = ConfigurationManager.AppSettings["DeliverooMenuId"];
        if (string.IsNullOrEmpty(token) || string.IsNullOrEmpty(brand) || string.IsNullOrEmpty(menuId)) throw new InvalidOperationException("Configura DeliverooClientId, DeliverooClientSecret, DeliverooBrandId e DeliverooMenuId");
        var url = "https://api-sandbox.developers.deliveroo.com/menu/v1/brands/" + HttpUtility.UrlEncode(brand) + "/menus/" + HttpUtility.UrlEncode(menuId);
        var request = (HttpWebRequest)WebRequest.Create(url);
        request.Method = "GET"; request.Headers["Authorization"] = "Bearer " + token;
        try
        {
            using (var response = (HttpWebResponse)request.GetResponse())
            using (var reader = new StreamReader(response.GetResponseStream())) return reader.ReadToEnd();
        }
        catch (WebException ex)
        {
            var http = ex.Response as HttpWebResponse;
            var detail = "";
            if (http != null) using (var reader = new StreamReader(http.GetResponseStream())) detail = reader.ReadToEnd();
            return new JavaScriptSerializer().Serialize(new { ok = false, status = http == null ? 0 : (int)http.StatusCode, response = detail, url = url });
        }
    }

    private string GetToken()
    {
        var clientId = ConfigurationManager.AppSettings["DeliverooClientId"];
        var clientSecret = ConfigurationManager.AppSettings["DeliverooClientSecret"];
        var request = (HttpWebRequest)WebRequest.Create("https://auth-sandbox.developers.deliveroo.com/oauth2/token");
        request.Method = "POST"; request.ContentType = "application/x-www-form-urlencoded";
        var body = "grant_type=client_credentials&client_id=" + HttpUtility.UrlEncode(clientId) + "&client_secret=" + HttpUtility.UrlEncode(clientSecret);
        var bytes = Encoding.UTF8.GetBytes(body); request.ContentLength = bytes.Length;
        using (var stream = request.GetRequestStream()) stream.Write(bytes, 0, bytes.Length);
        using (var response = (HttpWebResponse)request.GetResponse())
        using (var reader = new StreamReader(response.GetResponseStream()))
        {
            var data = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(reader.ReadToEnd());
            return Convert.ToString(data["access_token"]);
        }
    }
}
