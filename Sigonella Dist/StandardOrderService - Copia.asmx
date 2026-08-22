<%@ WebService Language="C#" Class="StandardOrderService" %>

using System;
using System.Collections;
using System.Collections.Generic;
using System.Configuration;
using System.Web;
using System.Net;
using System.Net.Mail;
using System.Text;
using System.Web.Services;
using System.Web.Script.Services;
using System.Web.Script.Serialization;
using MySql.Data.MySqlClient;

[WebService(Namespace = "http://tempuri.org/")]
[WebServiceBinding(ConformsTo = WsiProfiles.BasicProfile1_1)]
[ScriptService]
public class StandardOrderService : WebService
{
    private static object InternalValue(Dictionary<string, object> data, string key)
    {
        if (data == null) return null;
        if (data.ContainsKey(key)) return data[key];
        var tho = data.ContainsKey("tho") ? data["tho"] as Dictionary<string, object> : null;
        if (tho == null) return null;
        string thoKey = key == "locationName" ? "location_name" : key;
        return tho.ContainsKey(thoKey) ? tho[thoKey] : null;
    }

    private static object CustomerValue(Dictionary<string, object> data, string key)
    {
        var customer = data != null && data.ContainsKey("customer") ? data["customer"] as Dictionary<string, object> : null;
        return customer != null && customer.ContainsKey(key) ? customer[key] : null;
    }

    private static string LocationName(Dictionary<string, object> data)
    {
        var explicitName = Convert.ToString(InternalValue(data, "locationName") ?? "").Trim();
        if (!String.IsNullOrEmpty(explicitName)) return explicitName;
        var location = Convert.ToString(InternalValue(data, "location") ?? Value(data, "location_id", "")).Trim();
        switch (location)
        {
            case "0": return "Residence Marinai";
            case "1": return "NAS 1";
            case "2": return "NAS 2";
            case "3": return "Baia del Silenzio";
            case "5": return "Loreto Residence";
            case "7": return "Etnapolis";
            case "8": return "205 Residence";
            case "9": return "Pick-up at restaurant";
            default: return location;
        }
    }

    private static void CanonicalizeOrder(Dictionary<string, object> data)
    {
        if (data == null) return;

        var thoInput = data.ContainsKey("tho") ? data["tho"] as Dictionary<string, object> : null;
        if (!data.ContainsKey("status") || String.IsNullOrWhiteSpace(Convert.ToString(data["status"])))
        {
            if (thoInput != null && thoInput.ContainsKey("status")) data["status"] = thoInput["status"];
            else if (data.ContainsKey("stato") && Convert.ToDecimal(data["stato"]) >= 2m) data["status"] = "confirmed";
            else data["status"] = "submitted";
        }

        if (!data.ContainsKey("items"))
        {
            object legacyItems = data.ContainsKey("lines") ? data["lines"] : (data.ContainsKey("order") ? data["order"] : null);
            var legacyList = legacyItems as IList;
            if (legacyList != null)
            {
                var items = new List<Dictionary<string, object>>();
                foreach (object raw in legacyList)
                {
                    var line = raw as Dictionary<string, object>;
                    if (line == null) continue;
                    var item = new Dictionary<string, object>();
                    item["id"] = Value(line, "id", null);
                    item["name"] = Value(line, "name", Value(line, "product_name", ""));
                    item["quantity"] = Value(line, "quantity", Value(line, "count", 1));
                    item["unit_price"] = Value(line, "unit_price", Value(line, "price", 0));
                    item["price"] = Value(line, "price", Value(line, "unit_price", 0));
                    item["customer_notes"] = Value(line, "customer_notes", Value(line, "notes", ""));
                    items.Add(item);
                }
                data["items"] = items;
            }
        }

        var customer = data.ContainsKey("customer") ? data["customer"] as Dictionary<string, object> : null;
        if (customer == null) customer = new Dictionary<string, object>();
        if (!customer.ContainsKey("first_name")) customer["first_name"] = Value(data, "name", "");
        if (!customer.ContainsKey("last_name")) customer["last_name"] = "";
        if (!customer.ContainsKey("email")) customer["email"] = Value(data, "email", "");
        if (!customer.ContainsKey("phone")) customer["phone"] = Value(data, "phone", "");
        data["customer"] = customer;

        var tho = data.ContainsKey("tho") ? data["tho"] as Dictionary<string, object> : null;
        if (tho == null) tho = new Dictionary<string, object>();
        CopyIfMissing(tho, "date", data, "date");
        CopyIfMissing(tho, "location", data, "location");
        CopyIfMissing(tho, "location_name", data, "locationName");
        CopyIfMissing(tho, "notes", data, "notes");
        CopyIfMissing(tho, "issued", data, "issued");
        CopyIfMissing(tho, "has_whatsapp", data, "hasWhatsApp");
        CopyIfMissing(tho, "link", data, "link");
        CopyIfMissing(tho, "itinerario", data, "itinerario");
        tho.Remove("status");
        data["tho"] = tho;

        string[] legacy = { "name", "email", "phone", "iphone", "prefix", "notes", "location", "locationName", "date", "issued", "hasWhatsApp", "stato", "link", "itinerario", "lines", "order" };
        foreach (string key in legacy) data.Remove(key);
    }

    private static void CopyIfMissing(Dictionary<string, object> target, string targetKey, Dictionary<string, object> source, string sourceKey)
    {
        if (!target.ContainsKey(targetKey) && source.ContainsKey(sourceKey)) target[targetKey] = source[sourceKey];
    }

    private string ConnectionString
    {
        get { return ConfigurationManager.ConnectionStrings["MySqlConnectionString"].ConnectionString; }
    }

    [WebMethod]
    [ScriptMethod(ResponseFormat = ResponseFormat.Json)]
    public string GetMenu()
    {
        var categories = new List<Dictionary<string, object>>();
        using (var conn = new MySqlConnection(ConnectionString))
        {
            conn.Open();
            var categoryCommand = new MySqlCommand("SELECT id, name_en FROM v2_categories ORDER BY sort_order", conn);
            using (var reader = categoryCommand.ExecuteReader())
            {
                while (reader.Read())
                {
                    var category = new Dictionary<string, object>();
                    category["id"] = reader["id"];
                    category["name"] = reader["name_en"];
                    category["items"] = new List<object>();
                    categories.Add(category);
                }
            }

            var productCommand = new MySqlCommand("SELECT id, category_id, name, description_en, description_it, image_url, price, spiciness_level, is_delivery FROM v2_products WHERE is_active = 1", conn);
            using (var reader = productCommand.ExecuteReader())
            {
                while (reader.Read())
                {
                    var category = categories.Find(item => Convert.ToInt32(item["id"]) == Convert.ToInt32(reader["category_id"]));
                    if (category == null) continue;
                    var product = new Dictionary<string, object>();
                    product["id"] = reader["id"];
                    product["name"] = reader["name"];
                    product["eng"] = reader["description_en"] == DBNull.Value ? "" : reader["description_en"];
                    product["it"] = reader["description_it"] == DBNull.Value ? "" : reader["description_it"];
                    product["image"] = reader["image_url"] == DBNull.Value ? "" : reader["image_url"];
                    product["price"] = reader["price"];
                    product["spiciness"] = reader["spiciness_level"];
                    product["is_delivery"] = reader["is_delivery"] == DBNull.Value || Convert.ToBoolean(reader["is_delivery"]);
                    product["ingredients"] = new List<string>();
                    ((List<object>)category["items"]).Add(product);
                }
            }
        }
        return new JavaScriptSerializer().Serialize(categories);
    }

    [WebMethod]
    [ScriptMethod(ResponseFormat = ResponseFormat.Json)]
    public object CreateOrder(object form)
    {
        try
        {
            var data = form as Dictionary<string, object>;
            if (data == null) return new { ok = false, error = "Invalid order data." };
            CanonicalizeOrder(data);

            DateTime orderDate;
            string rawDate = InternalValue(data, "date") != null
                ? Convert.ToString(InternalValue(data, "date"))
                : "";
            if (!DateTime.TryParse(rawDate, out orderDate)) orderDate = DateTime.Today;

            string externalId = data.ContainsKey("external_order_id")
                ? Convert.ToString(data["external_order_id"])
                : (data.ContainsKey("uuid") ? Convert.ToString(data["uuid"]) :
                    (data.ContainsKey("id") ? Convert.ToString(data["id"]) : ""));
            string source = data.ContainsKey("source") ? Convert.ToString(data["source"]) : "sigonella-test";
            if (!data.ContainsKey("channel") || String.IsNullOrWhiteSpace(Convert.ToString(data["channel"])))
                data["channel"] = "Sigonella";
            string status = InternalValue(data, "status") != null ? Convert.ToString(InternalValue(data, "status")) : "submitted";
            decimal total = data.ContainsKey("total") ? Convert.ToDecimal(data["total"]) : 0m;

            if (!String.IsNullOrWhiteSpace(externalId))
                return UpdateExistingExternalOrder(data, externalId);

            long orderId;

            using (var conn = new MySqlConnection(ConnectionString))
            {
                conn.Open();
                if (String.IsNullOrWhiteSpace(externalId))
                {
                    using (var uuidCmd = new MySqlCommand("SELECT CAST(UUID() AS CHAR)", conn))
                    {
                        externalId = Convert.ToString(uuidCmd.ExecuteScalar());
                    }
                }
                data["id"] = externalId;
                data["uuid"] = externalId;
                data["external_order_id"] = externalId;
                string payload = new JavaScriptSerializer().Serialize(data);
                using (var tx = conn.BeginTransaction())
                {
                    using (var cmd = new MySqlCommand(@"
                        INSERT INTO external_order
                        (source, order_payload, confirmed_at_utc)
                        VALUES
                        (@source, @payload,
                         CASE WHEN @status = 'confirmed' THEN UTC_TIMESTAMP() ELSE NULL END)", conn, tx))
                    {
                        AddOrderParameters(cmd, data, source, externalId, status, total, payload);
                        cmd.ExecuteNonQuery();
                        orderId = cmd.LastInsertedId;
                    }

                    using (var eventCmd = new MySqlCommand(@"
                        INSERT INTO external_order_event
                        (external_order_id, event_type, new_status, event_payload)
                        VALUES (@order_id, 'created', @status, @payload)", conn, tx))
                    {
                        eventCmd.Parameters.AddWithValue("@order_id", orderId);
                        eventCmd.Parameters.AddWithValue("@status", status);
                        eventCmd.Parameters.AddWithValue("@payload", payload);
                        eventCmd.ExecuteNonQuery();
                    }
                    tx.Commit();
                }
            }
            bool notified = TrySendStandardOrderNotification(data, "created");
            return new { ok = true, id = externalId, uuid = externalId, db_id = orderId, external_order_id = externalId, notified = notified };
        }
        catch (Exception ex) { return new { ok = false, error = ex.Message }; }
    }

    private object UpdateExistingExternalOrder(Dictionary<string, object> data, string externalId)
    {
        string payload = new JavaScriptSerializer().Serialize(data);
        using (var conn = new MySqlConnection(ConnectionString))
        {
            conn.Open();
            using (var tx = conn.BeginTransaction())
            {
                long dbId;
                string oldStatus;
                using (var read = new MySqlCommand(@"
                    SELECT id, CAST(order_payload AS CHAR) AS order_payload
                    FROM external_order
                    WHERE external_order_id = @external_id
                    LIMIT 1
                    FOR UPDATE", conn, tx))
                {
                    read.Parameters.Add("@external_id", MySqlDbType.VarChar, 180).Value = externalId;
                    using (var reader = read.ExecuteReader())
                    {
                        if (!reader.Read()) return new { ok = false, error = "Order not found." };
                        dbId = Convert.ToInt64(reader["id"]);
                        var oldPayload = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(Convert.ToString(reader["order_payload"]));
                        oldStatus = InternalValue(oldPayload, "status") != null
                            ? Convert.ToString(InternalValue(oldPayload, "status"))
                            : (ToDecimal(oldPayload, "stato", 0m) >= 2m ? "confirmed" : "new");
                    }
                }

                if (String.Equals(oldStatus, "confirmed", StringComparison.OrdinalIgnoreCase) ||
                    String.Equals(oldStatus, "accepted", StringComparison.OrdinalIgnoreCase))
                    return new { ok = false, error = "Order is already confirmed and cannot be changed by the customer." };

                using (var update = new MySqlCommand(@"
                    UPDATE external_order
                    SET order_payload = @payload, updated_at_utc = UTC_TIMESTAMP()
                    WHERE external_order_id = @external_id", conn, tx))
                {
                    update.Parameters.AddWithValue("@payload", payload);
                    update.Parameters.Add("@external_id", MySqlDbType.VarChar, 180).Value = externalId;
                    update.ExecuteNonQuery();
                }

                using (var eventCmd = new MySqlCommand(@"
                    INSERT INTO external_order_event
                    (external_order_id, event_type, old_status, new_status, event_payload)
                    VALUES (@id, 'customer_updated', @old_status, @new_status, @payload)", conn, tx))
                {
                    eventCmd.Parameters.AddWithValue("@id", dbId);
                    eventCmd.Parameters.AddWithValue("@old_status", oldStatus);
                    eventCmd.Parameters.AddWithValue("@new_status", oldStatus);
                    eventCmd.Parameters.AddWithValue("@payload", payload);
                    eventCmd.ExecuteNonQuery();
                }
                tx.Commit();
                return new { ok = true, id = externalId, uuid = externalId, db_id = dbId, updated = true };
            }
        }
    }

    [WebMethod]
    [ScriptMethod(ResponseFormat = ResponseFormat.Json)]
    public object DeleteOrder(string id, string notificationType, string customMessage)
    {
        return SetExternalOrderDeleted(id, true, notificationType, customMessage);
    }

    [WebMethod]
    [ScriptMethod(ResponseFormat = ResponseFormat.Json)]
    public object RestoreOrder(string id)
    {
        return SetExternalOrderDeleted(id, false, "none", "");
    }

    [WebMethod]
    [ScriptMethod(ResponseFormat = ResponseFormat.Json)]
    public object CancelOrders(string locationId, string notificationType, string customMessage)
    {
        try
        {
            var cancelled = 0; var notified = 0;
            using (var conn = new MySqlConnection(ConnectionString))
            {
                conn.Open();
                var sql = "SELECT external_order_id, CAST(order_payload AS CHAR) AS order_payload FROM external_order WHERE channel = 'Sigonella' AND JSON_UNQUOTE(JSON_EXTRACT(order_payload, '$.tho.status')) = 'submitted' AND JSON_UNQUOTE(JSON_EXTRACT(order_payload, '$.tho.date')) = CURDATE()";
                if (!String.IsNullOrWhiteSpace(locationId) && locationId != "-1") sql += locationId == "99" ? " AND JSON_UNQUOTE(JSON_EXTRACT(order_payload, '$.tho.location')) IN ('0','1','2','8')" : " AND JSON_UNQUOTE(JSON_EXTRACT(order_payload, '$.tho.location')) = @location_id";
                using (var cmd = new MySqlCommand(sql, conn))
                {
                    if (!String.IsNullOrWhiteSpace(locationId) && locationId != "-1" && locationId != "99") cmd.Parameters.Add("@location_id", MySqlDbType.VarChar, 100).Value = locationId;
                    var selected = new List<Dictionary<string, object>>();
                    using (var reader = cmd.ExecuteReader())
                    {
                        while (reader.Read())
                        {
                            var selectedOrder = new Dictionary<string, object>();
                            selectedOrder["id"] = Convert.ToString(reader["external_order_id"]);
                            selectedOrder["payload"] = Convert.ToString(reader["order_payload"]);
                            selected.Add(selectedOrder);
                        }
                    }
                    foreach (var selectedOrder in selected)
                    {
                            var id = Convert.ToString(selectedOrder["id"]);
                            var payload = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(Convert.ToString(selectedOrder["payload"]));
                            payload["cancellation_message"] = notificationType == "custom" ? customMessage : notificationType == "customer_request" ? "This order was cancelled at your request." : notificationType == "too_late" ? "This order was placed too late to be prepared for the requested delivery time." : "This order was cancelled because the minimum order threshold for delivery was not reached.";
                            using (var update = new MySqlCommand("UPDATE external_order SET order_payload = JSON_SET(order_payload, '$.tho.status', 'cancelled'), updated_at_utc = UTC_TIMESTAMP() WHERE external_order_id = @id", conn))
                            { update.Parameters.Add("@id", MySqlDbType.VarChar, 180).Value = id; cancelled += update.ExecuteNonQuery(); }
                            if (notificationType != "none" && TrySendStandardOrderNotification(payload, "cancelled")) notified++;
                    }
                }
            }
            return new { ok = true, cancelled = cancelled, notified = notified };
        }
        catch (Exception ex) { return new { ok = false, error = ex.Message }; }
    }

    private object SetExternalOrderDeleted(string externalId, bool deleted, string notificationType, string customMessage)
    {
        try
        {
            if (String.IsNullOrWhiteSpace(externalId))
                return new { ok = false, error = "external_order_id is required." };

            using (var conn = new MySqlConnection(ConnectionString))
            {
                conn.Open();
                Dictionary<string, object> payload = null;
                using (var read = new MySqlCommand("SELECT CAST(order_payload AS CHAR) AS order_payload FROM external_order WHERE external_order_id = @external_id", conn))
                {
                    read.Parameters.Add("@external_id", MySqlDbType.VarChar, 180).Value = externalId;
                    using (var reader = read.ExecuteReader())
                    {
                        if (reader.Read()) payload = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(Convert.ToString(reader["order_payload"]));
                    }
                }
                using (var cmd = new MySqlCommand(@"
                    UPDATE external_order
                    SET order_payload = JSON_SET(order_payload, '$.Eliminato', IF(@deleted = 1, TRUE, FALSE)),
                        updated_at_utc = UTC_TIMESTAMP()
                    WHERE external_order_id = @external_id", conn))
                {
                    cmd.Parameters.Add("@deleted", MySqlDbType.Int32).Value = deleted ? 1 : 0;
                    cmd.Parameters.Add("@external_id", MySqlDbType.VarChar, 180).Value = externalId;
                    var affected = cmd.ExecuteNonQuery();
                    var notified = false;
                    if (affected > 0 && deleted && payload != null && notificationType != "none")
                    {
                        payload["cancellation_message"] = notificationType == "custom" ? customMessage :
                            notificationType == "customer_request" ? "This order was cancelled at your request." :
                            notificationType == "too_late" ? "This order was placed too late to be prepared for the requested delivery time." :
                            "This order was cancelled because the minimum order threshold for delivery was not reached.";
                        notified = TrySendStandardOrderNotification(payload, "cancelled");
                    }
                    return new { ok = affected > 0, id = externalId, deleted = deleted, notified = notified };
                }
            }
        }
        catch (Exception ex)
        {
            return new { ok = false, error = ex.Message };
        }
    }

    [WebMethod]
    [ScriptMethod(ResponseFormat = ResponseFormat.Json)]
    public object UpdateOrder(object form)
    {
        return UpdateOrderInternal(form, false);
    }

    [WebMethod]
    [ScriptMethod(ResponseFormat = ResponseFormat.Json)]
    public object UpdateConfirmedOrder(object form)
    {
        return UpdateOrderInternal(form, true);
    }

    [WebMethod]
    [ScriptMethod(ResponseFormat = ResponseFormat.Json)]
    public object ConfirmOrder(string orderId, string additionalInfo)
    {
        try
        {
            if (String.IsNullOrWhiteSpace(orderId)) return new { ok = false, error = "external_order_id is required." };
            using (var conn = new MySqlConnection(ConnectionString))
            {
                conn.Open();
                using (var cmd = new MySqlCommand(@"
                    UPDATE external_order
                    SET order_payload = JSON_SET(
                            JSON_SET(
                                JSON_SET(order_payload, '$.status', 'confirmed'),
                                '$.tho.status', 'confirmed'
                            ),
                            '$.stato', 2
                        ),
                        updated_at_utc = UTC_TIMESTAMP(),
                        confirmed_at_utc = COALESCE(confirmed_at_utc, UTC_TIMESTAMP())
                    WHERE (external_order_id = @id
                       OR JSON_UNQUOTE(JSON_EXTRACT(order_payload, '$.id')) = @id
                       OR JSON_UNQUOTE(JSON_EXTRACT(order_payload, '$.uuid')) = @id)
                      AND channel = 'Sigonella'
                      AND status NOT IN ('confirmed', 'accepted')", conn))
                {
                    cmd.Parameters.Add("@id", MySqlDbType.VarChar, 180).Value = orderId;
                    var affected = cmd.ExecuteNonQuery();
                    var notified = false;
                    if (affected > 0)
                    {
                        using (var read = new MySqlCommand("SELECT CAST(order_payload AS CHAR) AS order_payload FROM external_order WHERE external_order_id = @id", conn))
                        {
                            read.Parameters.Add("@id", MySqlDbType.VarChar, 180).Value = orderId;
                            using (var reader = read.ExecuteReader())
                            {
                                if (reader.Read())
                                {
                                    var payload = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(Convert.ToString(reader["order_payload"]));
                                    notified = TrySendStandardOrderNotification(payload, "confirmed");
                                }
                            }
                        }
                    }
                    return new { ok = affected > 0, id = orderId, confirmed = affected > 0, notified = notified };
                }
            }
        }
        catch (Exception ex) { return new { ok = false, error = ex.Message }; }
    }

    [WebMethod]
    [ScriptMethod(ResponseFormat = ResponseFormat.Json)]
    public object ConfirmOrders(string locationId, string dateScope, string additionalInfo)
    {
        try
        {
            using (var conn = new MySqlConnection(ConnectionString))
            {
                conn.Open();
                var sql = @"
                    UPDATE external_order
                    SET order_payload = JSON_SET(
                            JSON_SET(
                                JSON_SET(order_payload, '$.status', 'confirmed'),
                                '$.tho.status', 'confirmed'
                            ),
                            '$.stato', 2
                        ),
                        updated_at_utc = UTC_TIMESTAMP(),
                        confirmed_at_utc = COALESCE(confirmed_at_utc, UTC_TIMESTAMP())
                    WHERE channel = 'Sigonella'
                      AND status NOT IN ('confirmed', 'accepted')
                      AND JSON_UNQUOTE(JSON_EXTRACT(order_payload, '$.tho.date')) = @order_date";
                if (!String.IsNullOrWhiteSpace(locationId) && locationId != "-1")
                    sql += locationId == "99"
                        ? " AND JSON_UNQUOTE(JSON_EXTRACT(order_payload, '$.tho.location')) IN ('0','1','2','8')"
                        : " AND JSON_UNQUOTE(JSON_EXTRACT(order_payload, '$.tho.location')) = @location_id";
                using (var cmd = new MySqlCommand(sql, conn))
                {
                    var targetDate = String.Equals(dateScope, "tomorrow", StringComparison.OrdinalIgnoreCase)
                        ? DateTime.Today.AddDays(1) : DateTime.Today;
                    cmd.Parameters.Add("@order_date", MySqlDbType.Date).Value = targetDate;
                    if (!String.IsNullOrWhiteSpace(locationId) && locationId != "-1" && locationId != "99")
                        cmd.Parameters.Add("@location_id", MySqlDbType.VarChar, 100).Value = locationId;
                    var confirmed = cmd.ExecuteNonQuery();
                    using (var mailCmd = new MySqlCommand("SELECT CAST(order_payload AS CHAR) AS order_payload FROM external_order WHERE channel = 'Sigonella' AND JSON_UNQUOTE(JSON_EXTRACT(order_payload, '$.tho.status')) = 'confirmed' AND JSON_UNQUOTE(JSON_EXTRACT(order_payload, '$.tho.date')) = @order_date", conn))
                    {
                        mailCmd.Parameters.Add("@order_date", MySqlDbType.Date).Value = targetDate;
                        if (!String.IsNullOrWhiteSpace(locationId) && locationId != "-1" && locationId != "99")
                        {
                            mailCmd.CommandText += " AND JSON_UNQUOTE(JSON_EXTRACT(order_payload, '$.tho.location')) = @location_id";
                            mailCmd.Parameters.Add("@location_id", MySqlDbType.VarChar, 100).Value = locationId;
                        }
                        using (var reader = mailCmd.ExecuteReader())
                        {
                            while (reader.Read())
                            {
                                var payload = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(Convert.ToString(reader["order_payload"]));
                                TrySendStandardOrderNotification(payload, "confirmed");
                            }
                        }
                    }
                    return new { ok = true, confirmed = confirmed };
                }
            }
        }
        catch (Exception ex) { return new { ok = false, error = ex.Message }; }
    }

    [WebMethod]
    [ScriptMethod(ResponseFormat = ResponseFormat.Json)]
    public object SetExternalOrderStatus(string id, string status)
    {
        try
        {
            if (String.IsNullOrWhiteSpace(id)) return new { ok = false, error = "external_order_id is required." };
            var normalizedStatus = String.IsNullOrEmpty(status) ? "submitted" : status;
            var stato = normalizedStatus == "delivered" || normalizedStatus == "ready_for_collection" ? 5 : normalizedStatus == "ready_for_pickup" ? 4 : normalizedStatus == "in_transit" ? 3 : normalizedStatus == "confirmed" ? 2 : 1;
            using (var conn = new MySqlConnection(ConnectionString))
            {
                conn.Open();
                using (var cmd = new MySqlCommand(@"
                    UPDATE external_order
                    SET order_payload = JSON_SET(
                            JSON_SET(order_payload, '$.tho.status', @status),
                            '$.stato', @stato
                        ),
                        updated_at_utc = UTC_TIMESTAMP()
                    WHERE external_order_id = @id AND channel = 'Sigonella'", conn))
                {
                    cmd.Parameters.Add("@status", MySqlDbType.VarChar, 32).Value = normalizedStatus;
                    cmd.Parameters.Add("@stato", MySqlDbType.Int32).Value = stato;
                    cmd.Parameters.Add("@id", MySqlDbType.VarChar, 180).Value = id;
                    var affected = cmd.ExecuteNonQuery();
                    var notified = false;
                    if (affected > 0)
                    {
                        using (var read = new MySqlCommand("SELECT CAST(order_payload AS CHAR) AS order_payload FROM external_order WHERE external_order_id = @id", conn))
                        {
                            read.Parameters.Add("@id", MySqlDbType.VarChar, 180).Value = id;
                            using (var reader = read.ExecuteReader())
                            {
                                if (reader.Read())
                                {
                                    var payload = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(Convert.ToString(reader["order_payload"]));
                                    notified = TrySendStandardOrderNotification(payload, normalizedStatus == "ready_for_pickup" ? "ready_for_pickup" : normalizedStatus);
                                }
                            }
                        }
                    }
                    return new { ok = affected > 0, id = id, status = normalizedStatus, notified = notified };
                }
            }
        }
        catch (Exception ex) { return new { ok = false, error = ex.Message }; }
    }

    [WebMethod]
    [ScriptMethod(ResponseFormat = ResponseFormat.Json)]
    public object SendSingleArrivalNotification(string orderId)
    {
        return SetExternalOrderStatus(orderId, "ready_for_collection");
    }

    [WebMethod]
    [ScriptMethod(ResponseFormat = ResponseFormat.Json)]
    public object SendArrivalNotification(int locationId, string customName, string additionalInfo)
    {
        try
        {
            using (var conn = new MySqlConnection(ConnectionString))
            {
                conn.Open();
                var sql = @"
                    UPDATE external_order
                    SET order_payload = JSON_SET(JSON_SET(order_payload, '$.tho.status', 'ready_for_collection'), '$.stato', 5),
                        updated_at_utc = UTC_TIMESTAMP()
                    WHERE channel = 'Sigonella' AND JSON_UNQUOTE(JSON_EXTRACT(order_payload, '$.tho.status')) = 'in_transit' AND JSON_UNQUOTE(JSON_EXTRACT(order_payload, '$.tho.date')) = CURDATE()";
                if (locationId >= 0) sql += " AND JSON_UNQUOTE(JSON_EXTRACT(order_payload, '$.tho.location')) = @location_id";
                using (var cmd = new MySqlCommand(sql, conn))
                {
                    if (locationId >= 0) cmd.Parameters.Add("@location_id", MySqlDbType.VarChar, 100).Value = locationId.ToString();
                    var updated = cmd.ExecuteNonQuery();
                    var sent = 0;
                    using (var mailCmd = new MySqlCommand("SELECT CAST(order_payload AS CHAR) AS order_payload FROM external_order WHERE channel = 'Sigonella' AND JSON_UNQUOTE(JSON_EXTRACT(order_payload, '$.tho.status')) = 'ready_for_collection' AND JSON_UNQUOTE(JSON_EXTRACT(order_payload, '$.tho.date')) = CURDATE()", conn))
                    {
                        if (locationId >= 0) mailCmd.CommandText += " AND location_id = @location_id";
                        if (locationId >= 0) mailCmd.Parameters.Add("@location_id", MySqlDbType.VarChar, 100).Value = locationId.ToString();
                        using (var reader = mailCmd.ExecuteReader())
                        {
                            while (reader.Read())
                            {
                                var payload = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(Convert.ToString(reader["order_payload"]));
                                if (TrySendStandardOrderNotification(payload, "ready_for_collection")) sent++;
                            }
                        }
                    }
                    return new { ok = true, updated = updated, sent = sent };
                }
            }
        }
        catch (Exception ex) { return new { ok = false, error = ex.Message }; }
    }

    [WebMethod]
    [ScriptMethod(ResponseFormat = ResponseFormat.Json)]
    public object SendRiderTracking(List<string> orderIds, string mapUrl, string itineraryHtml, string additionalInfo)
    {
        try
        {
            var updated = 0;
            if (orderIds == null) return new { ok = false, error = "orderIds is required." };
            using (var conn = new MySqlConnection(ConnectionString))
            {
                conn.Open();
                foreach (var orderId in orderIds)
                {
                    using (var cmd = new MySqlCommand(@"
                        UPDATE external_order
                        SET order_payload = JSON_SET(JSON_SET(order_payload, '$.tho.status', 'in_transit'), '$.stato', 3),
                            updated_at_utc = UTC_TIMESTAMP()
                        WHERE external_order_id = @id AND channel = 'Sigonella'", conn))
                    {
                        cmd.Parameters.Add("@id", MySqlDbType.VarChar, 180).Value = orderId;
                        updated += cmd.ExecuteNonQuery();
                    }
                    using (var read = new MySqlCommand("SELECT CAST(order_payload AS CHAR) AS order_payload FROM external_order WHERE external_order_id = @id", conn))
                    {
                        read.Parameters.Add("@id", MySqlDbType.VarChar, 180).Value = orderId;
                        using (var reader = read.ExecuteReader())
                        {
                            if (reader.Read())
                            {
                                var payload = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(Convert.ToString(reader["order_payload"]));
                                payload["tracking_url"] = mapUrl ?? "";
                                payload["tracking_itinerary"] = itineraryHtml ?? "";
                                payload["tracking_notes"] = additionalInfo ?? "";
                                TrySendStandardOrderNotification(payload, "in_transit");
                            }
                        }
                    }
                }
            }
            return new { ok = true, updated = updated };
        }
        catch (Exception ex) { return new { ok = false, error = ex.Message }; }
    }

    [WebMethod]
    [ScriptMethod(ResponseFormat = ResponseFormat.Json)]
    public object SendBulkEmail(List<string> recipientEmails, string subject, string messageBody, List<string> orderIds)
    {
        try
        {
            if (orderIds == null || orderIds.Count == 0)
                return new { ok = false, error = "Nessun ordine selezionato." };
            var sent = 0;
            using (var conn = new MySqlConnection(ConnectionString))
            {
                conn.Open();
                foreach (var orderId in orderIds)
                {
                    using (var cmd = new MySqlCommand("SELECT CAST(order_payload AS CHAR) AS order_payload FROM external_order WHERE external_order_id = @id AND channel = 'Sigonella'", conn))
                    {
                        cmd.Parameters.Add("@id", MySqlDbType.VarChar, 180).Value = orderId;
                        using (var reader = cmd.ExecuteReader())
                        {
                            if (!reader.Read()) continue;
                            var data = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(Convert.ToString(reader["order_payload"]));
                            data["bulk_message"] = messageBody ?? "";
                            data["bulk_subject"] = subject ?? "Order Update - Thai Princess";
                            if (TrySendStandardOrderNotification(data, "bulk_custom")) sent++;
                        }
                    }
                }
            }
            return new { ok = true, sent = sent };
        }
        catch (Exception ex) { return new { ok = false, error = ex.Message }; }
    }

    [WebMethod]
    [ScriptMethod(ResponseFormat = ResponseFormat.Json)]
    public object SetOrderStatus(long id, string status)
    {
        try
        {
            if (String.IsNullOrEmpty(status)) return new { ok = false, error = "Status is required." };
            string payload;
            string oldStatus;
            using (var conn = new MySqlConnection(ConnectionString))
            {
                conn.Open();
                using (var tx = conn.BeginTransaction())
                {
                    using (var read = new MySqlCommand("SELECT status, CAST(order_payload AS CHAR) AS order_payload FROM external_order WHERE id = @id FOR UPDATE", conn, tx))
                    {
                        read.Parameters.AddWithValue("@id", id);
                        using (var reader = read.ExecuteReader())
                        {
                            if (!reader.Read()) return new { ok = false, error = "Order not found." };
                            oldStatus = Convert.ToString(reader["status"]);
                            payload = Convert.ToString(reader["order_payload"]);
                        }
                    }
                    using (var update = new MySqlCommand("UPDATE external_order SET order_payload = JSON_SET(order_payload, '$.tho.status', @status), updated_at_utc = UTC_TIMESTAMP() WHERE id = @id", conn, tx))
                    {
                        update.Parameters.AddWithValue("@status", status);
                        update.Parameters.AddWithValue("@id", id);
                        update.ExecuteNonQuery();
                    }
                    using (var eventCmd = new MySqlCommand(@"
                        INSERT INTO external_order_event (external_order_id, event_type, old_status, new_status, event_payload)
                        VALUES (@id, @type, @old_status, @new_status, @payload)", conn, tx))
                    {
                        eventCmd.Parameters.AddWithValue("@id", id);
                        eventCmd.Parameters.AddWithValue("@type", status);
                        eventCmd.Parameters.AddWithValue("@old_status", oldStatus);
                        eventCmd.Parameters.AddWithValue("@new_status", status);
                        eventCmd.Parameters.AddWithValue("@payload", payload);
                        eventCmd.ExecuteNonQuery();
                    }
                    tx.Commit();
                }
            }
            var data = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(payload);
            bool notified = TrySendStandardOrderNotification(data, status);
            return new { ok = true, id = id, notified = notified };
        }
        catch (Exception ex) { return new { ok = false, error = ex.Message }; }
    }

    [WebMethod]
    [ScriptMethod(ResponseFormat = ResponseFormat.Json)]
    public object GetPosOrders()
    {
        if (!IsPosAuthorized()) return new { ok = false, error = "Unauthorized POS request." };
        return GetOrders();
    }

    [WebMethod]
    [ScriptMethod(ResponseFormat = ResponseFormat.Json)]
    public object RegisterPosPayment(object form)
    {
        if (!IsPosAuthorized()) return new { ok = false, error = "Unauthorized POS request." };
        return UpdatePosPayment(form, false);
    }

    [WebMethod]
    [ScriptMethod(ResponseFormat = ResponseFormat.Json)]
    public object CancelPosCashPayment(object form)
    {
        if (!IsPosAuthorized()) return new { ok = false, error = "Unauthorized POS request." };
        return UpdatePosPayment(form, true);
    }

    private bool IsPosAuthorized()
    {
        var expected = ConfigurationManager.AppSettings["PosApiKey"];
        var supplied = HttpContext.Current == null ? "" : Convert.ToString(HttpContext.Current.Request.Headers["X-Api-Key"]);
        return !String.IsNullOrWhiteSpace(expected) && String.Equals(expected, supplied, StringComparison.Ordinal);
    }

    private object UpdatePosPayment(object form, bool cancel)
    {
        var data = form as Dictionary<string, object>;
        if (data != null && data.ContainsKey("form")) data = data["form"] as Dictionary<string, object>;
        if (data == null) return new { ok = false, error = "Invalid payment data." };
        var orderId = Convert.ToString(Value(data, "orderId", Value(data, "external_order_id", "")));
        if (String.IsNullOrWhiteSpace(orderId)) return new { ok = false, error = "external_order_id is required." };
        using (var conn = new MySqlConnection(ConnectionString))
        {
            conn.Open();
            var read = new MySqlCommand("SELECT id, CAST(order_payload AS CHAR) AS order_payload FROM external_order WHERE external_order_id=@id", conn);
            read.Parameters.AddWithValue("@id", orderId);
            long dbId; Dictionary<string, object> order;
            using (var reader = read.ExecuteReader())
            {
                if (!reader.Read()) return new { ok = false, error = "Order not found." };
                dbId = Convert.ToInt64(reader["id"]);
                order = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(Convert.ToString(reader["order_payload"]));
            }
            if (cancel) { order.Remove("pagamento"); order["status"] = "submitted"; order["payment_status"] = "unpaid"; }
            else { order["status"] = "paid"; order["payment_status"] = String.Equals(Convert.ToString(Value(data, "paymentStatus", "")), "CASH", StringComparison.OrdinalIgnoreCase) ? "paid cash" : "paid card"; order["tho"] = data; }
            var update = new MySqlCommand("UPDATE external_order SET order_payload=@payload, updated_at_utc=UTC_TIMESTAMP() WHERE id=@id", conn);
            update.Parameters.AddWithValue("@payload", new JavaScriptSerializer().Serialize(order)); update.Parameters.AddWithValue("@id", dbId); update.ExecuteNonQuery();
            return new { ok = true, external_order_id = orderId, status = order["status"] };
        }
    }

    private object UpdateOrderInternal(object form, bool confirmedUpdate)
    {
        try
        {
            var data = form as Dictionary<string, object>;
            if (data == null || !data.ContainsKey("id")) return new { ok = false, error = "Order id is required." };
            CanonicalizeOrder(data);

            string externalId = Convert.ToString(data["id"]);
            string payload = new JavaScriptSerializer().Serialize(data);
            decimal total = data.ContainsKey("total") ? Convert.ToDecimal(data["total"]) : 0m;
            string requestedStatus = InternalValue(data, "status") == null ? null : Convert.ToString(InternalValue(data, "status"));
            long orderId = 0;

            using (var conn = new MySqlConnection(ConnectionString))
            {
                conn.Open();
                using (var tx = conn.BeginTransaction())
                {
                    string oldStatus;
                    using (var read = new MySqlCommand("SELECT id, status FROM external_order WHERE external_order_id = @external_id FOR UPDATE", conn, tx))
                    {
                        read.Parameters.AddWithValue("@external_id", externalId);
                        using (var reader = read.ExecuteReader())
                        {
                            if (!reader.Read()) return new { ok = false, error = "Order not found." };
                            orderId = Convert.ToInt64(reader["id"]);
                            oldStatus = Convert.ToString(reader["status"]);
                        }
                    }

                    bool alreadyConfirmed = String.Equals(oldStatus, "confirmed", StringComparison.OrdinalIgnoreCase) ||
                        String.Equals(oldStatus, "accepted", StringComparison.OrdinalIgnoreCase);
                    if (!confirmedUpdate && alreadyConfirmed)
                        return new { ok = false, error = "Order is already confirmed and cannot be changed by the customer." };
                    if (confirmedUpdate && !alreadyConfirmed)
                        return new { ok = false, error = "Order is not confirmed yet." };

                    using (var update = new MySqlCommand(@"
                        UPDATE external_order
                        SET order_payload = @payload,
                            updated_at_utc = UTC_TIMESTAMP(),
                            price_updated_at_utc = CASE WHEN @confirmed_update = 1 THEN UTC_TIMESTAMP() ELSE price_updated_at_utc END
                        WHERE id = @id", conn, tx))
                    {
                        update.Parameters.AddWithValue("@total", total);
                        update.Parameters.AddWithValue("@status", (object)requestedStatus ?? DBNull.Value);
                        update.Parameters.AddWithValue("@payload", payload);
                        update.Parameters.AddWithValue("@confirmed_update", confirmedUpdate ? 1 : 0);
                        update.Parameters.AddWithValue("@customer_name", Value(data, "customer_name", Value(data, "name")) ?? DBNull.Value);
                        update.Parameters.AddWithValue("@customer_email", Value(data, "customer_email", Value(data, "email")) ?? DBNull.Value);
                        update.Parameters.AddWithValue("@customer_phone", Value(data, "customer_phone", Value(data, "phone")) ?? DBNull.Value);
                        update.Parameters.AddWithValue("@id", orderId);
                        update.ExecuteNonQuery();
                    }

                    using (var eventCmd = new MySqlCommand(@"
                        INSERT INTO external_order_event
                        (external_order_id, event_type, old_status, new_status, event_payload)
                        VALUES (@id, @event_type, @old_status, @new_status, @payload)", conn, tx))
                    {
                        eventCmd.Parameters.AddWithValue("@id", orderId);
                        eventCmd.Parameters.AddWithValue("@old_status", oldStatus);
                        eventCmd.Parameters.AddWithValue("@new_status", requestedStatus ?? oldStatus);
                        string recordedEvent = confirmedUpdate ? "price_updated" :
                            (String.Equals(requestedStatus, "confirmed", StringComparison.OrdinalIgnoreCase) ? "confirmed" :
                            (String.Equals(requestedStatus, "rejected", StringComparison.OrdinalIgnoreCase) ? "rejected" :
                            (String.Equals(requestedStatus, "cancelled", StringComparison.OrdinalIgnoreCase) ? "cancelled" : "customer_updated")));
                        eventCmd.Parameters.AddWithValue("@event_type", recordedEvent);
                        eventCmd.Parameters.AddWithValue("@payload", payload);
                        eventCmd.ExecuteNonQuery();
                    }
                    tx.Commit();
                }
            }
            string notificationType = confirmedUpdate ? "price_updated" : "customer_updated";
            bool notified = !String.IsNullOrEmpty(notificationType) && TrySendStandardOrderNotification(data, notificationType);
            return new { ok = true, id = externalId, db_id = orderId, notified = notified };
        }
        catch (Exception ex) { return new { ok = false, error = ex.Message }; }
    }

    [WebMethod]
    [ScriptMethod(ResponseFormat = ResponseFormat.Json)]
    public string GetOrders()
    {
        var serializer = new JavaScriptSerializer();
        try
        {
            var result = new List<object>();
            const string getOrdersSql = "SELECT CAST(order_payload AS CHAR) AS order_payload FROM external_order";
            using (var conn = new MySqlConnection(ConnectionString))
            {
                conn.Open();
                using (var cmd = new MySqlCommand(getOrdersSql, conn))
                using (var reader = cmd.ExecuteReader())
                {
                    while (reader.Read())
                    {
                        var payloadData = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(Convert.ToString(reader["order_payload"]));
                        var orderDateValue = InternalValue(payloadData, "date");
                        DateTime orderDate;
                        if (orderDateValue != null && DateTime.TryParse(Convert.ToString(orderDateValue), out orderDate) && orderDate.Date < DateTime.Today)
                        {
                            continue;
                        }
                        var externalId = Convert.ToString(Value(payloadData, "uuid", Value(payloadData, "id", "")));
                        var thoData = payloadData.ContainsKey("tho") ? payloadData["tho"] as Dictionary<string, object> : null;
                        var rawStatus = thoData != null && thoData.ContainsKey("status")
                            ? thoData["status"]
                            : InternalValue(payloadData, "status");
                        var status = rawStatus != null ? Convert.ToString(rawStatus) : "submitted";
                        if (rawStatus == null && ToDecimal(payloadData, "stato", 0m) >= 2m) status = "confirmed";
                        if (String.Equals(status, "new", StringComparison.OrdinalIgnoreCase)) status = "submitted";
                        if (String.Equals(status, "ready", StringComparison.OrdinalIgnoreCase)) status = "ready_for_pickup";
                        var totalValue = payloadData.ContainsKey("total") ? ToDecimal(payloadData, "total", 0m) : ToDecimal(payloadData, "totale", 0m);
                        var isDeleted = payloadData.ContainsKey("Eliminato") && payloadData["Eliminato"] != null && Convert.ToBoolean(payloadData["Eliminato"]);
                        result.Add(new {
                            id = externalId,
                            source = "sigonella",
                            channel = Convert.ToString(Value(payloadData, "channel", "Sigonella")),
                            external_order_id = externalId,
                            date = Convert.ToString(InternalValue(payloadData, "date") ?? ""),
                            location = InternalValue(payloadData, "location") ?? Value(payloadData, "location_id", null),
                            locationName = LocationName(payloadData),
                            order_number = Convert.ToString(Value(payloadData, "order_number", "")),
                            status = status,
                            service_type = Convert.ToString(Value(payloadData, "service_type", "delivery")),
                            customer = new {
                                first_name = Convert.ToString(CustomerValue(payloadData, "first_name") ?? Value(payloadData, "first_name", Value(payloadData, "name", ""))),
                                email = Convert.ToString(CustomerValue(payloadData, "email") ?? Value(payloadData, "email", "")),
                                phone = Convert.ToString(CustomerValue(payloadData, "phone") ?? Value(payloadData, "phone", ""))
                            },
                            customer_notes = !String.IsNullOrEmpty(Convert.ToString(InternalValue(payloadData, "notes") ?? ""))
                                ? Convert.ToString(InternalValue(payloadData, "notes") ?? "")
                                : Convert.ToString(Value(payloadData, "order_notes", "")),
                            total = totalValue,
                            currency = Convert.ToString(Value(payloadData, "currency", Value(payloadData, "currency_code", "EUR"))),
                            deleted = isDeleted,
                            created_at = InternalValue(payloadData, "issued"),
                            items = BuildStandardItems(payloadData)
                        });
                    }
                }
            }
            return serializer.Serialize(result);
        }
        catch (MySqlException ex)
        {
            return serializer.Serialize(new
            {
                ok = false,
                error = ex.Message,
                number = ex.Number,
                details = ex.ToString(),
                inner = ex.InnerException == null ? null : ex.InnerException.ToString(),
                query = "SELECT CAST(order_payload AS CHAR) AS order_payload FROM external_order"
            });
        }
        catch (Exception ex)
        {
            return serializer.Serialize(new { ok = false, error = ex.Message, exception = ex.GetType().FullName });
        }
    }

    private static List<Dictionary<string, object>> BuildStandardItems(Dictionary<string, object> data)
    {
        var result = new List<Dictionary<string, object>>();
        object rawLines = data.ContainsKey("items") ? data["items"] :
            (data.ContainsKey("lines") ? data["lines"] : data.ContainsKey("order") ? data["order"] : null);
        var lines = rawLines as System.Collections.IList;
        if (lines == null) return result;

        for (var i = 0; i < lines.Count; i++)
        {
            var line = lines[i] as Dictionary<string, object>;
            if (line == null) continue;
            var options = line.ContainsKey("options") && line["options"] != null
                ? line["options"]
                : new List<object>();
            result.Add(new Dictionary<string, object>
            {
                { "id", Value(line, "product_id", Value(line, "id")) },
                { "product_name", Value(line, "product_name", Value(line, "name", "")) },
                { "sku_name", Value(line, "sku_name", null) },
                { "quantity", ToDecimal(line, "quantity", ToDecimal(line, "count", 1m)) },
                { "price", ToDecimal(line, "price", ToDecimal(line, "unit_price", 0m)) },
                { "subtotal", ToDecimal(line, "subtotal", ToDecimal(line, "price", 0m) * ToDecimal(line, "quantity", ToDecimal(line, "count", 1m))) },
                { "customer_notes", Value(line, "customer_notes", Value(line, "notes", "")) },
                { "options", options }
            });
        }
        return result;
    }

    [WebMethod]
    [ScriptMethod(ResponseFormat = ResponseFormat.Json)]
    public object GetOrder(string id)
    {
        try
        {
            using (var conn = new MySqlConnection(ConnectionString))
            {
                conn.Open();
                string payload;
                using (var cmd = new MySqlCommand(@"
                    SELECT CAST(order_payload AS CHAR) AS order_payload
                    FROM external_order
                    WHERE external_order_id = @id
                    LIMIT 1", conn))
                {
                    cmd.Parameters.Add("@id", MySqlDbType.VarChar, 180).Value = (object)id ?? DBNull.Value;
                    using (var reader = cmd.ExecuteReader())
                    {
                        if (!reader.Read()) return new { ok = false, error = "Order not found." };
                        payload = Convert.ToString(reader["order_payload"]);
                    }
                }

                var payloadData = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(payload);
                if (payloadData == null) return new { ok = false, error = "Invalid order payload." };
                if (!payloadData.ContainsKey("id") || payloadData["id"] == null)
                    payloadData["id"] = payloadData.ContainsKey("uuid") ? payloadData["uuid"] : id;
                payloadData["external_order_id"] = id;
                return new { ok = true, order = payloadData };
            }
        }
        catch (Exception ex) { return new { ok = false, error = ex.Message }; }
    }

    private void AddOrderParameters(MySqlCommand cmd, Dictionary<string, object> data, string source, string externalId, string status, decimal total, string payload)
    {
        cmd.Parameters.AddWithValue("@source", source);
        cmd.Parameters.AddWithValue("@external_id", externalId);
        cmd.Parameters.AddWithValue("@order_number", Value(data, "order_number"));
        cmd.Parameters.AddWithValue("@status", status);
        cmd.Parameters.AddWithValue("@service_type", Value(data, "service_type", "delivery"));
        cmd.Parameters.AddWithValue("@customer_name", Value(data, "customer_name", Value(data, "name")) ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@customer_email", Value(data, "customer_email", Value(data, "email")) ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@customer_phone", Value(data, "customer_phone", Value(data, "phone")) ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@location_id", Value(data, "location_id"));
        cmd.Parameters.AddWithValue("@total", total);
        cmd.Parameters.AddWithValue("@currency", Value(data, "currency", "EUR"));
        cmd.Parameters.AddWithValue("@notes", Value(data, "notes"));
        cmd.Parameters.AddWithValue("@payload", payload);
    }

    private void InsertLines(MySqlConnection conn, MySqlTransaction tx, long orderId, IEnumerable rawLines)
    {
        if (rawLines == null) return;
        int lineNumber = 0;
        foreach (object raw in rawLines)
        {
            var line = raw as Dictionary<string, object>;
            if (line == null) continue;
            decimal quantity = ToDecimal(line, "quantity", 1m);
            decimal price = ToDecimal(line, "unit_price", 0m);
            decimal original = ToDecimal(line, "original_unit_price", price);
            using (var cmd = new MySqlCommand(@"
                INSERT INTO external_order_line
                (external_order_id, line_number, product_id, item_name, category_name,
                 quantity, unit_price, original_unit_price, line_total, notes, options_payload)
                VALUES (@order_id, @line, @product_id, @name, @category,
                        @quantity, @price, @original, @line_total, @notes, @options)", conn, tx))
            {
                cmd.Parameters.AddWithValue("@order_id", orderId);
                cmd.Parameters.AddWithValue("@line", lineNumber++);
                cmd.Parameters.AddWithValue("@product_id", Value(line, "product_id", Value(line, "id")));
                cmd.Parameters.AddWithValue("@name", Value(line, "name", "Articolo"));
                cmd.Parameters.AddWithValue("@category", Value(line, "category"));
                cmd.Parameters.AddWithValue("@quantity", quantity);
                cmd.Parameters.AddWithValue("@price", price);
                cmd.Parameters.AddWithValue("@original", original);
                cmd.Parameters.AddWithValue("@line_total", quantity * price);
                cmd.Parameters.AddWithValue("@notes", Value(line, "notes"));
                cmd.Parameters.AddWithValue("@options", line.ContainsKey("options") ? new JavaScriptSerializer().Serialize(line["options"]) : null);
                cmd.ExecuteNonQuery();
            }
        }
    }

    private static object Value(Dictionary<string, object> data, string key, object fallback = null)
    {
        return data.ContainsKey(key) && data[key] != null ? data[key] : fallback;
    }

    private static decimal ToDecimal(Dictionary<string, object> data, string key, decimal fallback)
    {
        decimal value;
        return data.ContainsKey(key) && Decimal.TryParse(Convert.ToString(data[key]), out value) ? value : fallback;
    }

    private bool TrySendStandardOrderNotification(Dictionary<string, object> data, string eventType)
    {
        try { return SendStandardOrderNotification(data, eventType); }
        catch { return false; }
    }

    private bool SendStandardOrderNotification(Dictionary<string, object> data, string eventType)
    {
        string recipient = Convert.ToString(Value(data, "customer_email", Value(data, "email")));
        if (String.IsNullOrEmpty(recipient) && data.ContainsKey("customer") && data["customer"] is Dictionary<string, object>)
            recipient = Convert.ToString(Value((Dictionary<string, object>)data["customer"], "email", ""));
        string smtpHost = ConfigurationManager.AppSettings["StandardOrderSmtpHost"];
        string smtpUser = ConfigurationManager.AppSettings["StandardOrderSmtpUser"];
        string smtpPassword = ConfigurationManager.AppSettings["StandardOrderSmtpPassword"];
        if (String.IsNullOrEmpty(recipient) || String.IsNullOrEmpty(smtpHost) || String.IsNullOrEmpty(smtpUser)) return false;

        string customer = Convert.ToString(Value(data, "customer_name", Value(data, "name", CustomerValue(data, "first_name") ?? "Customer")));
        string subject;
        string title;
        string intro;
        switch (eventType)
        {
            case "confirmed":
                subject = "Order Confirmed - Thai Princess";
                title = "Order Confirmed";
                intro = "Your order has been confirmed and is being prepared.";
                break;
            case "price_updated":
                subject = "Order Updated - Thai Princess";
                title = "Order Updated";
                intro = "We have adjusted the price of your order to reflect your requests. Here are the updated details:";
                break;
            case "customer_updated":
                subject = "Order Updated - Thai Princess";
                title = "Order Updated";
                intro = "Your order has been updated. Here are the updated details:";
                break;
            case "bulk_custom":
                subject = Convert.ToString(Value(data, "bulk_subject", "Order Update - Thai Princess"));
                title = "Order Update";
                intro = Convert.ToString(Value(data, "bulk_message", ""));
                break;
            case "rejected":
                subject = "Order Rejected - Thai Princess";
                title = "Order Rejected";
                intro = "Unfortunately, we cannot accept your order.";
                break;
            case "cancelled":
                subject = "Order Cancelled - Thai Princess";
                title = "Order Cancelled";
                intro = Convert.ToString(Value(data, "cancellation_message", "Your order has been cancelled."));
                break;
            case "ready_for_pickup":
                subject = "Order Ready for Pickup - Thai Princess";
                title = "Order Ready for Pickup";
                intro = "Your order is ready for pickup.";
                break;
            case "in_transit":
                subject = "Your Order Is On The Way - Thai Princess";
                title = "Order On The Way";
                intro = "Your order has left the restaurant and is on its way.";
                break;
            case "ready_for_collection":
                subject = "Order Ready to Collect - Thai Princess";
                title = "Order Ready to Collect";
                intro = "Your delivery has arrived and your order is ready to collect.";
                break;
            case "customer_arrived":
                subject = "Order Arrival - Thai Princess";
                title = "Customer Arrival";
                intro = "We have registered your arrival for this order.";
                break;
            default:
                subject = "Order Received - Thai Princess";
                title = "Order Received";
                intro = "We have received your order. Here are the details:";
                break;
        }
        var html = new StringBuilder();
        html.Append("<p>Dear " + Html(customer) + ",</p><p>" + Html(intro) + "</p>");
        html.Append("<table style='width:100%;border-collapse:collapse;margin-top:20px;color:#ffffff;'>");
        html.Append("<tr style='border-bottom:1px solid #444;'><th style='text-align:left;padding:10px;color:#D4AF37;'>Item</th><th style='text-align:center;padding:10px;color:#D4AF37;'>Qty</th><th style='text-align:right;padding:10px;color:#D4AF37;'>Price</th></tr>");
        IEnumerable lines = data.ContainsKey("items") ? data["items"] as IEnumerable :
            (data.ContainsKey("lines") ? data["lines"] as IEnumerable : null);
        if (lines != null)
        {
            foreach (object raw in lines)
            {
                var line = raw as Dictionary<string, object>;
                if (line == null) continue;
                decimal quantity = ToDecimal(line, "quantity", 1m);
                decimal price = ToDecimal(line, "price", ToDecimal(line, "unit_price", 0m));
                html.Append("<tr style='border-bottom:1px solid #444;'><td style='padding:10px;'>" + Html(Convert.ToString(Value(line, "product_name", Value(line, "name", "Item")))) + "</td>");
                html.Append("<td style='text-align:center;padding:10px;'>" + quantity.ToString("0.##") + "</td>");
                html.Append("<td style='text-align:right;padding:10px;'>&#8364; " + (quantity * price).ToString("N2") + "</td></tr>");
            }
        }
        html.Append("</table><p style='text-align:right;color:#D4AF37;font-weight:bold;'>Total: &#8364; " + ToDecimal(data, "total", 0m).ToString("N2") + "</p>");
        if (eventType == "in_transit")
        {
            string trackingUrl = Convert.ToString(Value(data, "tracking_url", ""));
            string trackingItinerary = Convert.ToString(Value(data, "tracking_itinerary", ""));
            string trackingNotes = Convert.ToString(Value(data, "tracking_notes", ""));
            if (!String.IsNullOrEmpty(trackingUrl)) html.Append("<p><strong>Track the rider:</strong> <a href='" + HttpUtility.HtmlAttributeEncode(trackingUrl) + "'>Open Google Maps</a></p>");
            if (!String.IsNullOrEmpty(trackingItinerary)) html.Append(trackingItinerary);
            if (!String.IsNullOrEmpty(trackingNotes)) html.Append("<p>" + Html(trackingNotes) + "</p>");
        }

        html.Append("<div style='margin-top:20px;border-top:1px solid #444;padding-top:20px;'>");
        html.Append("<h3 style='color:#D4AF37;'>Delivery Details</h3>");
        string locationName = LocationName(data);
        html.Append("<p><strong>Delivery location:</strong> " + Html(locationName) + "</p>");
        string serviceType = Convert.ToString(Value(data, "service_type", Value(data, "fulfillment_type", "")));
        if (!String.IsNullOrEmpty(serviceType)) html.Append("<p><strong>Service:</strong> " + Html(serviceType) + "</p>");
        string orderDate = Convert.ToString(InternalValue(data, "date") ?? "");
        if (!String.IsNullOrEmpty(orderDate)) html.Append("<p><strong>Delivery Date:</strong> " + Html(orderDate) + "</p>");
        string phone = Convert.ToString(Value(data, "customer_phone", CustomerValue(data, "phone") ?? Value(data, "phone", "")));
        if (!String.IsNullOrEmpty(phone)) html.Append("<p><strong>Phone:</strong> " + Html(phone) + "</p>");
        string notes = Convert.ToString(InternalValue(data, "notes") ?? "");
        if (!String.IsNullOrEmpty(notes)) html.Append("<p><strong>General Notes:</strong> " + Html(notes) + "</p>");
        string externalId = Convert.ToString(Value(data, "external_order_id", Value(data, "id", "")));
        if (!String.IsNullOrEmpty(externalId))
            html.Append("<p style='margin-top:20px;'><a href='https://www.thaiprincess.it/sigonella.html?id=" + HttpUtility.UrlEncode(externalId) + "' style='color:#D4AF37;text-decoration:none;border-bottom:1px dotted #D4AF37;'>Click here to Modify your Order</a></p>");
        html.Append("</div>");

        using (var mail = new MailMessage())
        {
            mail.From = new MailAddress(smtpUser, "Thai Princess Orders");
            mail.To.Add(recipient);
            mail.Subject = subject;
            mail.Body = WrapInPremiumTemplate(title, html.ToString());
            mail.IsBodyHtml = true;
            mail.BodyEncoding = Encoding.UTF8;
            mail.SubjectEncoding = Encoding.UTF8;
            mail.HeadersEncoding = Encoding.UTF8;
            mail.Headers.Add("Content-Type", "text/html; charset=utf-8");
            using (var smtp = new SmtpClient(smtpHost, 587))
            {
                smtp.EnableSsl = true;
                smtp.Credentials = new NetworkCredential(smtpUser, smtpPassword);
                smtp.Send(mail);
            }
        }
        return true;
    }

    private static string Html(string value)
    {
        return HttpUtility.HtmlEncode(value ?? "");
    }

    private string WrapInPremiumTemplate(string title, string content)
    {
        string bgDark = "#1a1a1a";
        string textGold = "#D4AF37";
        string textWhite = "#ffffff";
        string borderGold = "1px solid #D4AF37";

        var sb = new StringBuilder();
        sb.Append("<html><body style='background-color: " + bgDark + "; color: " + textWhite + "; font-family: Arial, sans-serif; padding: 20px;'>");
        sb.Append("<div style='max-width: 600px; margin: 0 auto; background-color: #2c2c2c; border: " + borderGold + "; border-radius: 8px; overflow: hidden;'>");
        sb.Append("<div style='background-color: #000; padding: 20px; text-align: center; border-bottom: " + borderGold + ";'>");
        sb.Append("<img src='https://www.thaiprincess.it/Thai-Princess%20GoldBlack%205.png' alt='Thai Princess Logo' style='max-width: 150px; height: auto; margin-bottom: 10px;'><br>");
        sb.Append("<h1 style='color: " + textGold + "; margin: 0;'>Thai Princess</h1>");
        if (!String.IsNullOrEmpty(title)) sb.Append("<p style='color: " + textWhite + "; margin: 5px 0 0;'>" + title + "</p>");
        sb.Append("</div>");
        sb.Append("<div style='padding: 20px;'>");
        sb.Append(content);
        sb.Append("</div>");
        sb.Append("<div style='background-color: #000; padding: 15px; text-align: center; font-size: 12px; color: #666; border-top: " + borderGold + ";'>");
        sb.Append("Thai Princess - Sigonella Delivery Service");
        sb.Append("</div>");
        sb.Append("</div></body></html>");
        return sb.ToString();
    }
}
