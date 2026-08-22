// Programma interattivo: chiede un importo da tastiera e invia una richiesta di pagamento
// (comando ECR-LAN "Payment", codice 'P') al terminale Nexi SmartPOS/PosConnector.
// Basato su "Payment | Traditional POS | Nexi group developer portal" (formato messaggio
// verificato campo per campo) e "Communication Protocol" (framing STX/ETX/LRC, ACK/NAK).
//
// Va eseguito con una carta fisica disponibile sul terminale: la transazione la completa la
// persona al terminale (inserimento/avvicinamento carta, eventuale PIN), questo programma si
// limita a mandare la richiesta e a mostrare l'esito che il terminale restituisce.

using System;
using System.Globalization;
using System.IO;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace NexiPaymentRequest;

internal static class Program
{
    private const string Version = "v1 (2026-07-31)";

    private static async Task<int> Main(string[] args)
    {
        if (args.Length < 3 || args[0] is "-h" or "--help" or "/?")
        {
            Console.WriteLine(Version);
            Console.WriteLine();
            Console.WriteLine("Uso: NexiPaymentRequest.exe <ip-terminale> <terminalId> <cashRegisterId> [porta=8081]");
            Console.WriteLine();
            Console.WriteLine("Programma interattivo: ad ogni INVIO chiede un importo e manda una richiesta di");
            Console.WriteLine("pagamento (ECR-LAN, comando 'P' - Payment) al terminale. Serve una carta fisica sul");
            Console.WriteLine("terminale per completare la transazione: il programma manda solo la richiesta e");
            Console.WriteLine("mostra l'esito restituito dal terminale.");
            return 3;
        }

        var host = args[0];
        var terminalId = NormalizeId(args[1]);
        var cashRegisterId = NormalizeId(args[2]);
        var port = args.Length > 3 && int.TryParse(args[3], out var p) ? p : 8081;

        Console.WriteLine(Version);
        Console.WriteLine($"Terminale: {host}:{port}   TerminalID: {terminalId}   CashRegisterID: {cashRegisterId}");
        Console.WriteLine("Premi INVIO senza importo per uscire.");
        Console.WriteLine();

        while (true)
        {
            Console.Write("Importo (EUR, es. 12.50): ");
            var input = Console.ReadLine();
            if (string.IsNullOrWhiteSpace(input)) break;

            if (!decimal.TryParse(input.Replace(',', '.'), NumberStyles.Number, CultureInfo.InvariantCulture, out var amountEur) || amountEur <= 0)
            {
                Console.WriteLine("Importo non valido, riprova.");
                continue;
            }

            var amountCents = (long)Math.Round(amountEur * 100, MidpointRounding.AwayFromZero);

            try
            {
                await RequestPayment(host, port, terminalId, cashRegisterId, amountCents);
            }
            catch (Exception ex)
            {
                Console.WriteLine($"ERRORE: {ex.Message}");
            }

            Console.WriteLine();
        }

        Console.WriteLine("Uscita.");
        return 0;
    }

    private static string NormalizeId(string raw)
    {
        var s = raw.PadLeft(8, '0');
        return s.Length > 8 ? s[^8..] : s;
    }

    private static async Task RequestPayment(string host, int port, string terminalId, string cashRegisterId, long amountCents)
    {
        var message = BuildPaymentMessage(terminalId, cashRegisterId, amountCents);
        var frame = BuildFrame(message);

        Console.WriteLine($"Invio richiesta di pagamento per EUR {amountCents / 100.0:0.00} ({amountCents} centesimi)...");

        using var client = new TcpClient();
        var connectTask = client.ConnectAsync(host, port);
        if (await Task.WhenAny(connectTask, Task.Delay(TimeSpan.FromSeconds(5))) != connectTask || !client.Connected)
        {
            Console.WriteLine("ERRORE: impossibile connettersi al terminale entro 5s.");
            return;
        }

        using var stream = client.GetStream();
        await stream.WriteAsync(frame, 0, frame.Length);
        Console.WriteLine("Richiesta inviata, in attesa di conferma fisica (ACK/NAK)...");

        var confirmation = await ReadExactly(stream, 3, TimeSpan.FromSeconds(5));
        if (confirmation == null)
        {
            Console.WriteLine("ERRORE: nessuna conferma fisica ricevuta entro 5s.");
            return;
        }
        if (confirmation[0] == 0x15)
        {
            Console.WriteLine("Il terminale ha risposto NAK alla richiesta: rifiutata, nessuna transazione avviata.");
            return;
        }
        if (confirmation[0] != 0x06)
        {
            Console.WriteLine("Risposta inattesa alla richiesta: " + Convert.ToHexString(confirmation));
            return;
        }

        Console.WriteLine("Richiesta accettata (ACK). In attesa che la transazione venga completata sul");
        Console.WriteLine("terminale (carta, eventuale PIN)... fino a 90 secondi.");

        var response = await ReadApplicationPacket(stream, TimeSpan.FromSeconds(90));
        if (response == null)
        {
            Console.WriteLine("ERRORE: nessuna risposta di pagamento ricevuta entro 90s (timeout).");
            return;
        }

        var ackLrc = ComputeLrc(new byte[] { 0x06, 0x03 });
        await stream.WriteAsync(new byte[] { 0x06, 0x03, ackLrc }, 0, 3);

        ParseAndPrintPaymentResponse(response);
    }

    private static string BuildPaymentMessage(string terminalId, string cashRegisterId, long amountCents)
    {
        var amountStr = amountCents.ToString(CultureInfo.InvariantCulture).PadLeft(8, '0');
        if (amountStr.Length > 8) throw new ArgumentException("Importo troppo alto per il campo (max 999999.99 EUR).");

        var sb = new StringBuilder();
        sb.Append(terminalId);         // pos 1-8
        sb.Append('0');                // pos 9 riservato
        sb.Append('P');                // pos 10 codice messaggio: Payment
        sb.Append(cashRegisterId);     // pos 11-18
        sb.Append('0');                // pos 19: messaggio dati aggiuntivi assente
        sb.Append("00");               // pos 20-21 riservato
        sb.Append('0');                // pos 22: carta non ancora inserita
        sb.Append('0');                // pos 23: tipo pagamento automatico
        sb.Append(amountStr);          // pos 24-31 importo in centesimi
        sb.Append(' ', 128);           // pos 32-159 testo di stampa (vuoto)
        sb.Append("00000000");         // pos 160-167 riservato

        var result = sb.ToString();
        if (result.Length != 167)
            throw new InvalidOperationException($"Lunghezza messaggio errata: {result.Length} (attesi 167).");
        return result;
    }

    private static byte[] BuildFrame(string message)
    {
        var messageBytes = Encoding.ASCII.GetBytes(message);
        var payloadForLrc = new byte[messageBytes.Length + 1];
        Array.Copy(messageBytes, payloadForLrc, messageBytes.Length);
        payloadForLrc[messageBytes.Length] = 0x03; // ETX incluso nel calcolo LRC
        var lrc = ComputeLrc(payloadForLrc);

        var frame = new byte[1 + messageBytes.Length + 1 + 1];
        frame[0] = 0x02; // STX
        Array.Copy(messageBytes, 0, frame, 1, messageBytes.Length);
        frame[1 + messageBytes.Length] = 0x03; // ETX
        frame[1 + messageBytes.Length + 1] = lrc;
        return frame;
    }

    private static byte ComputeLrc(byte[] bytes)
    {
        byte lrc = 0x7F;
        foreach (var b in bytes) lrc ^= b;
        return lrc;
    }

    private static async Task<byte[]?> ReadExactly(NetworkStream stream, int count, TimeSpan timeout)
    {
        var buffer = new byte[count];
        var offset = 0;
        using var cts = new CancellationTokenSource(timeout);
        try
        {
            while (offset < count)
            {
                var n = await stream.ReadAsync(buffer, offset, count - offset, cts.Token);
                if (n <= 0) return null;
                offset += n;
            }
            return buffer;
        }
        catch (OperationCanceledException)
        {
            return null;
        }
    }

    private static async Task<byte[]?> ReadApplicationPacket(NetworkStream stream, TimeSpan timeout)
    {
        // STX + messaggio (N byte) + ETX + LRC. N non e' noto a priori: si legge byte per byte
        // finche' non si incontra ETX seguito da un altro byte (il LRC).
        var buffer = new MemoryStream();
        var oneByte = new byte[1];
        using var cts = new CancellationTokenSource(timeout);
        try
        {
            while (true)
            {
                var n = await stream.ReadAsync(oneByte, 0, 1, cts.Token);
                if (n <= 0) return null;
                buffer.Write(oneByte, 0, 1);
                var bytes = buffer.ToArray();
                if (bytes.Length >= 3 && bytes[^2] == 0x03) return bytes;
                if (bytes.Length > 4096) return null; // salvaguardia contro flussi anomali
            }
        }
        catch (OperationCanceledException)
        {
            return null;
        }
    }

    private static void ParseAndPrintPaymentResponse(byte[] frame)
    {
        Console.WriteLine("Risposta ricevuta (hex): " + Convert.ToHexString(frame));
        if (frame.Length < 3 || frame[0] != 0x02)
        {
            Console.WriteLine("Formato inatteso (non inizia con STX).");
            return;
        }

        var message = Encoding.ASCII.GetString(frame, 1, frame.Length - 3); // esclude STX, ETX, LRC
        if (message.Length < 12)
        {
            Console.WriteLine("Messaggio troppo corto per essere interpretato.");
            return;
        }

        var code = message[9];
        var result = message.Substring(10, 2);
        Console.WriteLine($"Codice messaggio: '{code}'   Esito: {result}");

        if (result == "00" && message.Length >= 40)
        {
            var pan = message.Substring(12, 19).TrimStart('0');
            var maskedPan = pan.Length > 4 ? new string('*', Math.Max(0, pan.Length - 4)) + pan[^4..] : pan;
            var txType = message.Substring(31, 3);
            var authCode = message.Substring(34, 6);
            Console.WriteLine("ESITO: PAGAMENTO OK");
            Console.WriteLine($"  Carta (mascherata):    {maskedPan}");
            Console.WriteLine($"  Tipo transazione:      {txType}");
            Console.WriteLine($"  Codice autorizzazione: {authCode}");
        }
        else if (result == "01" && message.Length >= 36)
        {
            var reason = message.Substring(12, 24).Trim();
            Console.WriteLine("ESITO: PAGAMENTO RIFIUTATO/KO");
            Console.WriteLine($"  Motivo: {reason}");
        }
        else if (result == "05")
        {
            Console.WriteLine("ESITO: carta non presente.");
        }
        else
        {
            Console.WriteLine($"ESITO: codice risultato non riconosciuto o messaggio incompleto ({result}).");
        }

        if (message.Length >= 48)
        {
            var cardType = message[47];
            var cardTypeDesc = cardType switch { '1' => "Bancomat", '2' => "Carta di credito", '3' => "Altro", _ => "?" };
            Console.WriteLine($"  Tipo carta: {cardTypeDesc}");
        }
    }
}
