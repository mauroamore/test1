<%@ WebService Language="C#" Class="StandardOrderServiceDemo" %>

using System;
using System.Collections.Generic;
using System.Configuration;
using System.Web;
using System.Web.Services;
using System.Web.Script.Services;
using System.Web.Script.Serialization;
using MySql.Data.MySqlClient;

[WebService(Namespace = "http://tempuri.org/")]
[WebServiceBinding(ConformsTo = WsiProfiles.BasicProfile1_1)]
[ScriptService]
public class StandardOrderServiceDemo : WebService
{
    private const string DefaultDemoKey = "NEXI-DEMO-THAI-PRINCESS-2026";
    private string ConnectionString { get { return ConfigurationManager.ConnectionStrings["MySqlConnectionString"].ConnectionString; } }

    [WebMethod]
    [ScriptMethod(ResponseFormat = ResponseFormat.Json)]
    public string GetPosOrders()
    {
        if (!IsAuthorized()) return Json(new { ok = false, error = "Unauthorized demo POS request." });
        var result = new List<object>();
        using (var conn = new MySqlConnection(ConnectionString))
        using (var cmd = new MySqlCommand("SELECT order_payload FROM demo_order ORDER BY id", conn))
        {
            conn.Open();
            using (var reader = cmd.ExecuteReader())
                while (reader.Read()) result.Add(new JavaScriptSerializer().DeserializeObject(Convert.ToString(reader["order_payload"])));
        }
        return Json(result);
    }

    [WebMethod]
    [ScriptMethod(ResponseFormat = ResponseFormat.Json)]
    public string ReservePosOrder(object form)
    {
        if (!IsAuthorized()) return Json(new { ok = false, error = "Unauthorized demo POS request." });
        var data = form as Dictionary<string, object>;
        if (data != null && data.ContainsKey("form")) data = data["form"] as Dictionary<string, object>;
        var orderId = Convert.ToString(Value(data, "orderId", "DEMO-ORDER-0001"));
        using (var conn = new MySqlConnection(ConnectionString))
        using (var cmd = new MySqlCommand("SELECT payment_status FROM demo_order WHERE external_order_id=@id", conn))
        {
            conn.Open(); cmd.Parameters.AddWithValue("@id", orderId);
            var status = Convert.ToString(cmd.ExecuteScalar());
            if (String.IsNullOrWhiteSpace(status)) return Json(new { ok = false, reason = "not_found" });
            if (String.Equals(status, "paid", StringComparison.OrdinalIgnoreCase)) return Json(new { ok = false, reason = "already_paid" });
        }
        return Json(new { ok = true, demo = true, orderId = orderId, lockToken = Guid.NewGuid().ToString(), expiresInSeconds = 300 });
    }

    [WebMethod]
    [ScriptMethod(ResponseFormat = ResponseFormat.Json)]
    public string RegisterPosPayment(object form)
    {
        if (!IsAuthorized()) return Json(new { ok = false, error = "Unauthorized demo POS request." });
        var data = form as Dictionary<string, object>;
        if (data != null && data.ContainsKey("form")) data = data["form"] as Dictionary<string, object>;
        if (data == null) return Json(new { ok = false, error = "Invalid payment data." });
        var amount = DecimalValue(data, "paidAmount", 0.10m);
        var paymentStatus = Convert.ToString(Value(data, "paymentStatus", "CAPTURED"));
        var transactionId = Convert.ToString(Value(data, "transactionId", "DEMO-TRANSACTION-0001"));
        var terminalId = Convert.ToString(Value(data, "terminalId", "DEMO-TERMINAL"));
        var orderId = Convert.ToString(Value(data, "orderId", "DEMO-ORDER-0001"));
        var receipt = BuildReceipt(amount, paymentStatus, transactionId, terminalId);
        using (var conn = new MySqlConnection(ConnectionString))
        using (var cmd = new MySqlCommand("SELECT order_payload FROM demo_order WHERE external_order_id=@id", conn))
        {
            conn.Open(); cmd.Parameters.AddWithValue("@id", orderId);
            Dictionary<string, object> payload;
            using (var reader = cmd.ExecuteReader())
            {
                if (!reader.Read()) return Json(new { ok = false, error = "Demo order not found." });
                payload = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(Convert.ToString(reader["order_payload"]));
            }
            payload["pagamento"] = new Dictionary<string, object> { { "paidAmount", amount }, { "paymentStatus", paymentStatus }, { "transactionId", transactionId }, { "terminalId", terminalId }, { "pos_receipt", receipt }, { "fiscal_receipt", receipt } };
            payload["status"] = "paid";
            payload["payment_status"] = String.Equals(paymentStatus, "CASH", StringComparison.OrdinalIgnoreCase) ? "paid cash" : "paid card";
            using (var update = new MySqlCommand("UPDATE demo_order SET order_payload=@payload, status='paid', payment_status=@payment WHERE external_order_id=@id", conn))
            { update.Parameters.AddWithValue("@payload", Json(payload)); update.Parameters.AddWithValue("@payment", paymentStatus); update.Parameters.AddWithValue("@id", orderId); update.ExecuteNonQuery(); }
        }
        return Json(new {
            ok = true,
            demo = true,
            status = "paid",
            external_order_id = orderId,
            receipt = receipt
        });
    }

    [WebMethod]
    [ScriptMethod(ResponseFormat = ResponseFormat.Json)]
    public string CancelPosCashPayment(object form)
    {
        if (!IsAuthorized()) return Json(new { ok = false, error = "Unauthorized demo POS request." });
        return Json(new { ok = true, demo = true, status = "unpaid" });
    }

    [WebMethod]
    [ScriptMethod(ResponseFormat = ResponseFormat.Json)]
    public string ResetDemoData()
    {
        if (!IsAuthorized()) return Json(new { ok = false, error = "Unauthorized demo POS request." });
        using (var conn = new MySqlConnection(ConnectionString))
        using (var cmd = new MySqlCommand("DELETE FROM demo_order", conn)) { conn.Open(); cmd.ExecuteNonQuery(); }
        using (var conn = new MySqlConnection(ConnectionString))
        using (var cmd = new MySqlCommand("INSERT INTO demo_order (external_order_id, order_payload, status, payment_status) VALUES (@id,@payload,'confirmed','unpaid')", conn))
        { conn.Open(); cmd.Parameters.AddWithValue("@id", "DEMO-ORDER-0001"); cmd.Parameters.AddWithValue("@payload", Json(SeedDemoOrder())); cmd.ExecuteNonQuery(); }
        return Json(new { ok = true, demo = true, message = "Demo data reset completed." });
    }

    private static Dictionary<string, object> SeedDemoOrder()
    {
        return new Dictionary<string, object> {
            { "id", "DEMO-ORDER-0001" }, { "uuid", "DEMO-ORDER-0001" }, { "external_order_id", "DEMO-ORDER-0001" },
            { "tho", new Dictionary<string, object> { { "date", DateTime.Now.ToString("yyyy-MM-dd") }, { "location", "0" }, { "location_name", "Residence Marinai" }, { "status", "confirmed" } } },
            { "items", new[] { new { id = 1, name = "1 Thung Tong", product_name = "1 Thung Tong", quantity = 1, count = 1, price = 7.00m, unit_price = 7.00m }, new { id = 27, name = "2 Tod Man Muu", product_name = "2 Tod Man Muu", quantity = 1, count = 1, price = 7.00m, unit_price = 7.00m } } },
            { "total", 14.00m }, { "status", "confirmed" }, { "payment_status", "unpaid" }, { "channel", "Nexi Demo" },
            { "customer", new Dictionary<string, object> { { "first_name", "Cliente Demo Nexi" }, { "last_name", "" }, { "email", "demo@nexi.test" }, { "phone", "" } } }, { "currency", "EUR" }
        };
    }

    private bool IsAuthorized()
    {
        var expected = ConfigurationManager.AppSettings["PosDemoApiKey"];
        if (String.IsNullOrWhiteSpace(expected)) expected = DefaultDemoKey;
        var supplied = HttpContext.Current == null ? "" : Convert.ToString(HttpContext.Current.Request.Headers["X-Api-Key"]);
        var mode = HttpContext.Current == null ? "" : Convert.ToString(HttpContext.Current.Request.Headers["X-Pos-Mode"]);
        return String.Equals(mode, "demo", StringComparison.OrdinalIgnoreCase) && String.Equals(expected, supplied, StringComparison.Ordinal);
    }

    private static object BuildReceipt(decimal amount, string paymentStatus, string transactionId, string terminalId)
    {
        return new {
            businessName = "SIAM S.R.L.",
            fiscalAddressLines = new[] { "D.F. / ESERC.: VIALE", "AFRICA N.31" },
            vatNumber = "05129050877",
            items = new[] { new { quantity = 1, description = "1 Thung Tong", vatDepartment = "REPARTO IVA 10%", vatRate = "10%", price = amount } },
            total = amount,
            vatTotal = Math.Round(amount * 10m / 110m, 2),
            paymentMethod = String.Equals(paymentStatus, "CASH", StringComparison.OrdinalIgnoreCase) ? "CONTANTI" : "CARTA",
            paidAmount = amount,
            dateTime = DateTime.Now.ToString("dd-MM-yyyy HH:mm"),
            documentNumber = "DEMO-0001",
            rtCode = "DEMO-RT-0000000000",
            storeNumber = "0001",
            cashRegisterNumber = "001",
            transactionId = transactionId,
            terminalId = terminalId
        };
    }

    private static string Json(object value) { return new JavaScriptSerializer().Serialize(value); }
    private static object Value(Dictionary<string, object> data, string key, object fallback)
    { return data != null && data.ContainsKey(key) && data[key] != null ? data[key] : fallback; }
    private static decimal DecimalValue(Dictionary<string, object> data, string key, decimal fallback)
    { decimal value; return Decimal.TryParse(Convert.ToString(Value(data, key, fallback)), out value) ? value : fallback; }
}
