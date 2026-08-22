using System;
using System.Collections.Generic;
using System.IO;
using System.Net.Http;
using System.Net.Sockets;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace NexiEcr17Check;

internal static class Program
{
    private const string Version = "v6 (2026-08-01) — fix porta Epson (80, non 9100) + paytest/modi LRC";

    private static async Task<int> Main(string[] args)
    {
        if (args.Length < 1 || args[0] is "-h" or "--help" or "/?")
        {
            PrintUsage();
            return 3;
        }

        if (args[0] is "-v" or "--version")
        {
            Console.WriteLine(Version);
            return 0;
        }

        if (string.Equals(args[0], "epson", StringComparison.OrdinalIgnoreCase))
        {
            var epsonArgs = new string[args.Length - 1];
            Array.Copy(args, 1, epsonArgs, 0, epsonArgs.Length);
            return await RunEpsonCheck(epsonArgs);
        }

        if (string.Equals(args[0], "posconnector", StringComparison.OrdinalIgnoreCase))
        {
            var pcArgs = new string[args.Length - 1];
            Array.Copy(args, 1, pcArgs, 0, pcArgs.Length);
            return await RunPosConnectorCheck(pcArgs);
        }

        if (string.Equals(args[0], "paytest", StringComparison.OrdinalIgnoreCase))
        {
            var payArgs = new string[args.Length - 1];
            Array.Copy(args, 1, payArgs, 0, payArgs.Length);
            return await RunPaymentTest(payArgs);
        }

        // Uso storico senza sottocomando: NexiEcr17Check.exe <ip> [porta] [secondi] => check Nexi.
        return await RunNexiCheck(args);
    }

    private static void PrintUsage()
    {
        Console.WriteLine(Version);
        Console.WriteLine();
        Console.WriteLine("Uso:");
        Console.WriteLine("  NexiEcr17Check.exe <ip-terminale> [porta=1000] [secondi-ascolto=5]");
        Console.WriteLine("      Verifica passiva (nessun comando protocollo inviato) del terminale Nexi (ECR17/37).");
        Console.WriteLine();
        Console.WriteLine("  NexiEcr17Check.exe posconnector <ip-terminale> [porta=8081] [terminalId=00000000] [modo=auto]");
        Console.WriteLine("      Invia una 'Terminal Status Request' (sola lettura, non e' un pagamento) all'app");
        Console.WriteLine("      PosConnector/Scambio Importo via protocollo ECR-LAN, e mostra la risposta grezza.");
        Console.WriteLine("      modo/LRC: etx | noetx | stxetx | stx | zero");
        Console.WriteLine();
        Console.WriteLine("  NexiEcr17Check.exe paytest <ip-terminale> [porta=8081] [terminalId] [cashRegisterId=00000001] [centesimi=1]");
        Console.WriteLine("      Invia una richiesta Payment reale. Usare importi minimi e POS a portata di mano.");
        Console.WriteLine();
        Console.WriteLine("  NexiEcr17Check.exe epson <ip-stampante> [password-operatore] [devid=local_printer]");
        Console.WriteLine("      Verifica la stampante fiscale Epson (Fiscal ePOS-Print XML, porta web standard 80).");
        Console.WriteLine("      Senza password: solo queryPrinterStatus (nessun login, nessun effetto collaterale).");
        Console.WriteLine("      Con password: login + lettura libro giornale di oggi.");
    }

    // ================= NEXI ECR17/37 (verifica di rete passiva) =================

    private static async Task<int> RunNexiCheck(string[] args)
    {
        var host = args[0];
        var port = args.Length > 1 && int.TryParse(args[1], out var p) ? p : 1000;
        var listenSeconds = args.Length > 2 && int.TryParse(args[2], out var s) ? s : 5;

        var report = new StringBuilder();
        void Log(string line)
        {
            Console.WriteLine(line);
            report.AppendLine(line);
        }

        var startedAt = DateTime.Now;
        Log($"=== NexiEcr17Check === ({Version})");
        Log($"Data/ora:        {startedAt:yyyy-MM-dd HH:mm:ss}");
        Log($"Terminale:       {host}:{port}");
        Log($"Ascolto passivo: {listenSeconds}s dopo la connessione, nessun byte inviato al terminale.");
        Log("");

        var exitCode = 0;
        using var client = new TcpClient();
        try
        {
            var connectTask = client.ConnectAsync(host, port);
            var timeoutTask = Task.Delay(TimeSpan.FromSeconds(5));
            var completed = await Task.WhenAny(connectTask, timeoutTask);

            if (completed == timeoutTask || !client.Connected)
            {
                Log("ESITO: TIMEOUT — nessuna risposta di connessione entro 5s.");
                Log("Possibili cause: IP errato, terminale spento/non in rete, oppure firewall che scarta i pacchetti silenziosamente.");
                exitCode = 2;
            }
            else
            {
                Log($"ESITO: CONNESSO in {(DateTime.Now - startedAt).TotalMilliseconds:F0} ms.");
                Log("Qualcosa ascolta su questa porta: buon segno per l'abilitazione ECR17/37 lato Nexi.");
                Log($"In ascolto per {listenSeconds}s per eventuali byte non richiesti dal terminale...");

                using var stream = client.GetStream();
                var buffer = new byte[4096];
                var received = new MemoryStream();
                using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(listenSeconds));
                try
                {
                    while (true)
                    {
                        var n = await stream.ReadAsync(buffer, 0, buffer.Length, cts.Token);
                        if (n <= 0) break;
                        received.Write(buffer, 0, n);
                    }
                }
                catch (OperationCanceledException)
                {
                    // fine finestra di ascolto, normale
                }

                var bytes = received.ToArray();
                if (bytes.Length > 0)
                {
                    Log($"Ricevuti {bytes.Length} byte non richiesti dal terminale:");
                    Log("  hex  : " + Convert.ToHexString(bytes));
                    Log("  ascii: " + EscapeForLog(Encoding.Latin1.GetString(bytes)));
                }
                else
                {
                    Log("Nessun dato ricevuto spontaneamente (normale: molti ECR restano in attesa passiva di un comando).");
                }
            }
        }
        catch (SocketException ex) when (ex.SocketErrorCode == SocketError.ConnectionRefused)
        {
            Log("ESITO: RIFIUTATA — il terminale e' raggiungibile ma nulla ascolta su questa porta.");
            Log("ECR17/37 probabilmente NON abilitato su questa porta lato Nexi: da segnalare al referente.");
            exitCode = 1;
        }
        catch (SocketException ex)
        {
            Log($"ESITO: ERRORE DI RETE — {ex.SocketErrorCode}: {ex.Message}");
            exitCode = 4;
        }
        catch (Exception ex)
        {
            Log($"ESITO: ERRORE — {ex.Message}");
            exitCode = 4;
        }

        await WriteReport("NexiEcr17Check", startedAt, report.ToString());
        return exitCode;
    }

    // ================= NEXI PosConnector / Scambio Importo (protocollo ECR-LAN) =================
    //
    // Basato su "Communication Protocol" e "Terminal status request message (from ECR)" del
    // developer portal Nexi (developer.nexigroup.com/traditionalpos). Framing:
    //   STX (0x02) + application message (N byte) + ETX (0x03) + LRC (1 byte)
    // LRC = XOR di ogni byte (messaggio + ETX), valore base 0x7F. Confermato empiricamente il
    // 2026-07-31 sul NAK di risposta di un terminale reale (byte "15 03 69"):
    // 0x7F XOR 0x15 (NAK) XOR 0x03 (ETX) = 0x69 — il calcolo copre anche l'ETX, non solo il
    // messaggio applicativo (la documentazione da sola non lo chiariva).
    //
    // Terminal Status Request (10 byte): ID terminale (8 cifre) + '0' riservato + 's'.
    // E' una richiesta di sola lettura (stato del terminale), non avvia nessun pagamento.

    private static async Task<int> RunPosConnectorCheck(string[] args)
    {
        if (args.Length < 1)
        {
            PrintUsage();
            return 3;
        }

        var host = args[0];
        var port = args.Length > 1 && int.TryParse(args[1], out var p) ? p : 8081;
        var terminalId = (args.Length > 2 ? args[2] : "00000000").PadLeft(8, '0');
        if (terminalId.Length > 8) terminalId = terminalId.Substring(terminalId.Length - 8);
        var lrcMode = args.Length > 3 ? args[3].Trim().ToLowerInvariant() : "etx";

        var report = new StringBuilder();
        void Log(string line)
        {
            Console.WriteLine(line);
            report.AppendLine(line);
        }

        var startedAt = DateTime.Now;
        Log($"=== PosConnectorCheck (Scambio Importo / ECR-LAN) === ({Version})");
        Log($"Data/ora:    {startedAt:yyyy-MM-dd HH:mm:ss}");
        Log($"Terminale:   {host}:{port}");
        Log($"Terminal ID: {terminalId}");
        Log($"LRC mode:    {lrcMode}");
        Log("Comando:     Terminal Status Request (sola lettura, nessun pagamento avviato)");
        Log("");

        // LRC confermato empiricamente sul NAK di risposta del terminale reale (15 03 69):
        // 0x7F XOR 0x15 XOR 0x03 = 0x69 -> il calcolo copre messaggio + ETX, non solo il messaggio.
        var appMessage = Encoding.ASCII.GetBytes(terminalId + "0s");
        var lrc = lrcMode switch
        {
            "noetx" => ComputeLrc(appMessage),
            "stxetx" => ComputeLrc(JoinBytes(0x02, appMessage, 0x03)),
            "stx" => ComputeLrc(JoinBytes(0x02, appMessage)),
            "zero" => ComputeLrcFrom(0x00, JoinBytes(appMessage, 0x03)),
            _ => ComputeLrc(JoinBytes(appMessage, 0x03))
        };
        var frame = new byte[1 + appMessage.Length + 1 + 1];
        frame[0] = 0x02; // STX
        Array.Copy(appMessage, 0, frame, 1, appMessage.Length);
        frame[1 + appMessage.Length] = 0x03; // ETX
        frame[1 + appMessage.Length + 1] = lrc;

        Log("Frame inviato (hex): " + Convert.ToHexString(frame));
        Log("");

        var exitCode = 0;
        try
        {
            using var client = new TcpClient();
            var connectTask = client.ConnectAsync(host, port);
            var timeoutTask = Task.Delay(TimeSpan.FromSeconds(5));
            if (await Task.WhenAny(connectTask, timeoutTask) == timeoutTask || !client.Connected)
            {
                Log("ESITO: TIMEOUT in connessione.");
                exitCode = 2;
            }
            else
            {
                using var stream = client.GetStream();
                await stream.WriteAsync(frame, 0, frame.Length);
                Log("Frame inviato, in attesa di risposta (fino a 5s)...");

                var buffer = new byte[4096];
                using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(5));
                var received = new MemoryStream();
                try
                {
                    while (true)
                    {
                        var n = await stream.ReadAsync(buffer, 0, buffer.Length, cts.Token);
                        if (n <= 0) break;
                        received.Write(buffer, 0, n);
                        if (received.Length > 0 && buffer[n - 1] == 0x03) break; // ETX ricevuto, fine messaggio
                    }
                }
                catch (OperationCanceledException) { }

                var bytes = received.ToArray();
                if (bytes.Length == 0)
                {
                    Log("ESITO: NESSUNA RISPOSTA entro 5s. Porta aperta ma il terminale non ha risposto al frame.");
                    Log("Possibile causa: framing/LRC non corretto (vedi nota sopra), oppure comando non gestito.");
                    exitCode = 1;
                }
                else
                {
                    Log($"Risposta ricevuta ({bytes.Length} byte):");
                    Log("  hex  : " + Convert.ToHexString(bytes));
                    Log("  ascii: " + EscapeForLog(Encoding.ASCII.GetString(Array.ConvertAll(bytes, b => b < 0x80 ? b : (byte)'.'))));

                    if (bytes.Length == 1 && bytes[0] == 0x06) Log("  -> ACK singolo (0x06): comando accettato, nessun dato applicativo in questo frame.");
                    else if (bytes.Length >= 1 && bytes[0] == 0x15) Log("  -> NAK (0x15): terminale ha rifiutato il frame. Cause possibili (da documentazione Nexi): " +
                        "errore di protocollo (codice messaggio o Terminal ID non valido), errore di parita', o errore LRC. " +
                        "Se il LRC del frame inviato coincide con la formula 0x7F XOR (messaggio+ETX), il sospetto principale e' il Terminal ID.");
                    else if (bytes.Length >= 1 && bytes[0] == 0x02) Log("  -> Inizia con STX: sembra un messaggio applicativo di risposta (status/dati).");

                    exitCode = 0;
                }
            }
        }
        catch (SocketException ex) when (ex.SocketErrorCode == SocketError.ConnectionRefused)
        {
            Log("ESITO: RIFIUTATA — nulla ascolta su questa porta.");
            exitCode = 1;
        }
        catch (Exception ex)
        {
            Log($"ESITO: ERRORE — {ex.Message}");
            exitCode = 4;
        }

        await WriteReport("PosConnectorCheck", startedAt, report.ToString());
        return exitCode;
    }

    private static byte ComputeLrc(byte[] messageBytes)
    {
        byte lrc = 0x7F;
        foreach (var b in messageBytes) lrc ^= b;
        return lrc;
    }

    private static byte ComputeLrcFrom(byte startValue, params byte[][] parts)
    {
        var lrc = startValue;
        foreach (var part in parts)
        {
            foreach (var b in part) lrc ^= b;
        }
        return lrc;
    }

    private static byte[] JoinBytes(params object[] parts)
    {
        var bytes = new List<byte>();
        foreach (var part in parts)
        {
            if (part is byte b) bytes.Add(b);
            else if (part is int i) bytes.Add(checked((byte)i));
            else if (part is byte[] array) bytes.AddRange(array);
        }
        return bytes.ToArray();
    }

    private static async Task<int> RunPaymentTest(string[] args)
    {
        if (args.Length < 1)
        {
            PrintUsage();
            return 3;
        }

        var host = args[0];
        var port = args.Length > 1 && int.TryParse(args[1], out var p) ? p : 8081;
        var terminalId = NormalizeNumeric(args.Length > 2 ? args[2] : "00000000", 8);
        var cashRegisterId = NormalizeNumeric(args.Length > 3 ? args[3] : "00000001", 8);
        var cents = args.Length > 4 && int.TryParse(args[4], out var c) ? c : 1;
        if (cents < 1 || cents > 99999999)
        {
            Console.WriteLine("Importo non valido: usare centesimi tra 1 e 99999999.");
            return 3;
        }

        var report = new StringBuilder();
        void Log(string line)
        {
            Console.WriteLine(line);
            report.AppendLine(line);
        }

        var startedAt = DateTime.Now;
        Log($"=== PosConnectorPaymentTest (Scambio Importo / ECR-LAN) === ({Version})");
        Log($"Data/ora:        {startedAt:yyyy-MM-dd HH:mm:ss}");
        Log($"Terminale:       {host}:{port}");
        Log($"Terminal ID:     {terminalId}");
        Log($"Cash register:   {cashRegisterId}");
        Log($"Importo:         {cents} centesimi");
        Log("LRC mode:        stxetx");
        Log("Comando:         Payment Request REALE");
        Log("");

        var appMessage = BuildPaymentApplicationMessage(terminalId, cashRegisterId, cents);
        var frame = BuildFrame(appMessage, "stxetx");
        Log($"Application message length: {appMessage.Length} byte");
        Log("Frame inviato (hex): " + Convert.ToHexString(frame));
        Log("");

        try
        {
            using var client = new TcpClient();
            var connectTask = client.ConnectAsync(host, port);
            if (await Task.WhenAny(connectTask, Task.Delay(TimeSpan.FromSeconds(5))) != connectTask || !client.Connected)
            {
                Log("ESITO: TIMEOUT in connessione.");
                await WriteReport("PosConnectorPaymentTest", startedAt, report.ToString());
                return 2;
            }

            using var stream = client.GetStream();
            await stream.WriteAsync(frame, 0, frame.Length);
            Log("Payment Request inviata, in attesa di ACK/progressi/esito finale (fino a 120s)...");

            var exitCode = await ReadPaymentConversation(stream, Log);
            await WriteReport("PosConnectorPaymentTest", startedAt, report.ToString());
            return exitCode;
        }
        catch (SocketException ex) when (ex.SocketErrorCode == SocketError.ConnectionRefused)
        {
            Log("ESITO: RIFIUTATA - nulla ascolta su questa porta.");
            await WriteReport("PosConnectorPaymentTest", startedAt, report.ToString());
            return 1;
        }
        catch (Exception ex)
        {
            Log($"ESITO: ERRORE - {ex.Message}");
            await WriteReport("PosConnectorPaymentTest", startedAt, report.ToString());
            return 4;
        }
    }

    private static byte[] BuildPaymentApplicationMessage(string terminalId, string cashRegisterId, int cents)
    {
        var text = "TEST SCAMBIO IMPORTO".PadLeft(128, ' ');
        var message =
            terminalId +
            "0" +
            "P" +
            cashRegisterId +
            "0" +
            "00" +
            "0" +
            "0" +
            cents.ToString().PadLeft(8, '0') +
            text +
            "00000000";
        return Encoding.ASCII.GetBytes(message);
    }

    private static byte[] BuildFrame(byte[] appMessage, string lrcMode)
    {
        var lrc = lrcMode switch
        {
            "noetx" => ComputeLrc(appMessage),
            "stxetx" => ComputeLrc(JoinBytes(0x02, appMessage, 0x03)),
            "stx" => ComputeLrc(JoinBytes(0x02, appMessage)),
            "zero" => ComputeLrcFrom(0x00, JoinBytes(appMessage, 0x03)),
            _ => ComputeLrc(JoinBytes(appMessage, 0x03))
        };
        return JoinBytes(0x02, appMessage, 0x03, lrc);
    }

    private static async Task<int> ReadPaymentConversation(NetworkStream stream, Action<string> log)
    {
        var buffer = new byte[4096];
        using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(120));
        try
        {
            while (true)
            {
                var n = await stream.ReadAsync(buffer, 0, buffer.Length, cts.Token);
                if (n <= 0)
                {
                    log("Connessione chiusa dal terminale.");
                    return 1;
                }

                var bytes = buffer[..n];
                log($"Ricevuti {n} byte:");
                log("  hex  : " + Convert.ToHexString(bytes));
                log("  ascii: " + EscapeForLog(Encoding.ASCII.GetString(Array.ConvertAll(bytes, b => b < 0x80 ? b : (byte)'.'))));
                DescribePaymentChunk(bytes, log);

                if (bytes.Length >= 1 && bytes[0] == 0x15)
                {
                    log("ESITO: NAK alla Payment Request.");
                    return 1;
                }

                var stxIndex = Array.IndexOf(bytes, (byte)0x02);
                if (stxIndex >= 0 && TryExtractApplicationPacket(bytes[stxIndex..], out var appMessage))
                {
                    await stream.WriteAsync(new byte[] { 0x06, 0x03, ComputeLrc(JoinBytes(0x06, 0x03)) });
                    log("ACK inviato per la risposta applicativa.");

                    var text = Encoding.ASCII.GetString(appMessage);
                    if (text.Length >= 10 && (text[9] == 'E' || text[9] == 'V'))
                    {
                        log("ESITO FINALE PAYMENT:");
                        log("  message code: " + text[9]);
                        if (text.Length >= 12) log("  result code : " + text.Substring(10, 2));
                        if (text.Length >= 36 && text.Substring(10, 2) == "01") log("  descrizione : " + text.Substring(12, 24).Trim());
                        return 0;
                    }
                }
            }
        }
        catch (OperationCanceledException)
        {
            log("ESITO: TIMEOUT in attesa dell'esito pagamento.");
            return 2;
        }
    }

    private static void DescribePaymentChunk(byte[] bytes, Action<string> log)
    {
        if (bytes.Length >= 3 && bytes[0] is 0x06 or 0x15 && bytes[1] == 0x03)
        {
            var expected = ComputeLrc(JoinBytes(bytes[0], bytes[1]));
            log($"  controllo: {(bytes[0] == 0x06 ? "ACK" : "NAK")} LRC {(bytes[2] == expected ? "ok" : "non valido")}");
        }
        if (bytes.Length > 0 && bytes[0] == 0x01) log("  progress: messaggio SOH/EOT dal terminale.");
    }

    private static bool TryExtractApplicationPacket(byte[] bytes, out byte[] appMessage)
    {
        appMessage = Array.Empty<byte>();
        if (bytes.Length < 4 || bytes[0] != 0x02) return false;
        var etxIndex = Array.IndexOf(bytes, (byte)0x03, 1);
        if (etxIndex < 0 || etxIndex + 1 >= bytes.Length) return false;
        appMessage = bytes[1..etxIndex];
        return true;
    }

    private static string NormalizeNumeric(string value, int length)
    {
        value = Regex.Replace(value, "[^0-9]", "");
        if (value.Length == 0) value = "0";
        value = value.PadLeft(length, '0');
        return value.Length > length ? value.Substring(value.Length - length) : value;
    }

    // ================= EPSON Fiscal ePOS-Print XML (stampante fiscale) =================

    // Porta web standard (80), non 9100 come inizialmente assunto — verificato empiricamente
    // il 2026-08-01: fpmate.cgi risponde su http://<ip>/cgi-bin/fpmate.cgi senza porta esplicita.
    private const int EpsonPort = 80;

    private static async Task<int> RunEpsonCheck(string[] args)
    {
        if (args.Length < 1)
        {
            PrintUsage();
            return 3;
        }

        var host = args[0];
        var password = args.Length > 1 ? args[1] : null;
        var devid = args.Length > 2 ? args[2] : "local_printer";

        var report = new StringBuilder();
        void Log(string line)
        {
            Console.WriteLine(line);
            report.AppendLine(line);
        }

        var startedAt = DateTime.Now;
        Log($"=== EpsonFiscalCheck === ({Version})");
        Log($"Data/ora:   {startedAt:yyyy-MM-dd HH:mm:ss}");
        Log($"Stampante:  {host}:{EpsonPort} (devid={devid})");
        Log("");

        using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(10) };
        var exitCode = 0;

        try
        {
            Log("--- queryPrinterStatus (statusType RT) ---");
            var status = await SendCommand(http, host, devid,
                $"<queryPrinterStatus operator=\"\" statusType=\"1\" />");
            LogFiscalResult(Log, status);

            if (string.IsNullOrEmpty(password))
            {
                Log("");
                Log("Nessuna password fornita: mi fermo qui (niente login/query giornale).");
                exitCode = status.Success ? 0 : 1;
            }
            else
            {
                Log("");
                Log("--- login ---");
                var loginData = ("02" + password).PadRight(100).Substring(0, 100);
                var loginResult = await SendCommand(http, host, devid,
                    $"<directIO operator=\"1\" command=\"4038\" data=\"{EscapeXml(loginData)}\" />");
                LogFiscalResult(Log, loginResult);

                if (!loginResult.Success)
                {
                    Log("Login fallito, mi fermo qui.");
                    exitCode = 1;
                }
                else
                {
                    Log("");
                    Log("--- queryContentByDate (oggi) ---");
                    var today = DateTime.Now;
                    var journal = await SendCommand(http, host, devid,
                        $"<queryContentByDate operator=\"1\" dataType=\"0\" " +
                        $"fromDay=\"{today.Day}\" fromMonth=\"{today.Month}\" fromYear=\"{today.Year}\" " +
                        $"toDay=\"{today.Day}\" toMonth=\"{today.Month}\" toYear=\"{today.Year}\" />");
                    LogFiscalResult(Log, journal);
                    exitCode = journal.Success ? 0 : 1;
                }
            }
        }
        catch (TaskCanceledException)
        {
            Log("ESITO: TIMEOUT — nessuna risposta dalla stampante entro 10s.");
            Log("Possibili cause: IP errato, stampante spenta/non in rete, oppure firewall che scarta i pacchetti.");
            exitCode = 2;
        }
        catch (HttpRequestException ex)
        {
            Log($"ESITO: ERRORE DI RETE — {ex.Message}");
            exitCode = 2;
        }
        catch (Exception ex)
        {
            Log($"ESITO: ERRORE — {ex.Message}");
            exitCode = 4;
        }

        await WriteReport("EpsonFiscalCheck", startedAt, report.ToString());
        return exitCode;
    }

    private static void LogFiscalResult(Action<string> log, FiscalResponse r)
    {
        log($"  success={r.Success} code=\"{r.Code}\" status=\"{r.Status}\"");
        if (r.Lines.Count > 0)
        {
            log($"  {r.Lines.Count} riga/e dal giornale:");
            foreach (var line in r.Lines) log("    " + line);
        }
    }

    private static async Task<FiscalResponse> SendCommand(HttpClient http, string host, string devid, string innerXml)
    {
        var url = $"http://{host}:{EpsonPort}/cgi-bin/fpmate.cgi?devid={Uri.EscapeDataString(devid)}&timeout=10000";
        var body =
            "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n" +
            "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\">\n" +
            "  <s:Body>\n" +
            "    <printerCommand>\n" +
            $"      {innerXml}\n" +
            "    </printerCommand>\n" +
            "  </s:Body>\n" +
            "</s:Envelope>";

        using var content = new StringContent(body, Encoding.UTF8, "text/xml");
        using var response = await http.PostAsync(url, content);
        var text = await response.Content.ReadAsStringAsync();
        return ParseFiscalResponse(text);
    }

    private static FiscalResponse ParseFiscalResponse(string xml)
    {
        var result = new FiscalResponse { Raw = xml };
        var responseMatch = Regex.Match(xml, "<response\\b([^>]*)/?>", RegexOptions.IgnoreCase);
        if (responseMatch.Success)
        {
            foreach (Match m in Regex.Matches(responseMatch.Groups[1].Value, "(\\w+)=\"([^\"]*)\""))
            {
                var name = m.Groups[1].Value;
                var value = m.Groups[2].Value;
                if (name == "success") result.Success = value == "true";
                else if (name == "code") result.Code = value;
                else if (name == "status") result.Status = value;
            }
        }
        foreach (Match m in Regex.Matches(xml, "<lineNumber\\d+>([\\s\\S]*?)</lineNumber\\d+>"))
        {
            result.Lines.Add(m.Groups[1].Value);
        }
        return result;
    }

    private static string EscapeXml(string s) =>
        s.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;").Replace("\"", "&quot;");

    private sealed class FiscalResponse
    {
        public string Raw { get; set; } = "";
        public bool Success { get; set; }
        public string Code { get; set; } = "";
        public string Status { get; set; } = "";
        public List<string> Lines { get; } = new();
    }

    // ================= comuni =================

    private static async Task WriteReport(string prefix, DateTime startedAt, string content)
    {
        var reportPath = Path.Combine(
            AppContext.BaseDirectory,
            $"{prefix}-report-{startedAt:yyyyMMdd-HHmmss}.txt");
        await File.WriteAllTextAsync(reportPath, content);
        Console.WriteLine();
        Console.WriteLine($"Report salvato in: {reportPath}");
    }

    private static string EscapeForLog(string s) => s.Replace("\r", "\\r").Replace("\n", "\\n").Replace("\t", "\\t");
}
