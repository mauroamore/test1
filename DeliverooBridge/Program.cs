using System;
using System.IO;
using System.Net;
using System.Linq;
using System.Windows.Forms;

namespace DeliverooBridge;

internal static class Program
{
    [STAThread]
    private static void Main(string[] args)
    {
        if (args.Length > 0 && string.Equals(args[0], "upload", StringComparison.OrdinalIgnoreCase))
        {
            try
            {
                if (args.Length < 2)
                    throw new ArgumentException("Uso: DeliverooBridge.exe upload <file>[=<percorso/remoto.ext>] [file...]");
                var passwordPath = Path.Combine(AppContext.BaseDirectory, PasswordFile);
                if (!File.Exists(passwordPath)) throw new FileNotFoundException("Manca ftp-password.txt", passwordPath);
                var password = File.ReadAllText(passwordPath).Trim();
                if (string.IsNullOrWhiteSpace(password)) throw new InvalidOperationException("ftp-password.txt e vuoto.");
                foreach (var arg in args.Skip(1))
                {
                    var separatorIndex = arg.IndexOf('=');
                    var source = separatorIndex < 0 ? arg : arg.Substring(0, separatorIndex);
                    var remotePath = separatorIndex < 0 ? null : arg.Substring(separatorIndex + 1);
                    MainForm.UploadFile(source, password, remotePath);
                }
                Console.WriteLine("UPLOAD_OK");
                return;
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine("UPLOAD_ERROR: " + ex.Message);
                Environment.ExitCode = 1;
                return;
            }
        }
        ApplicationConfiguration.Initialize();
        Application.Run(new MainForm());
    }

    internal const string FtpRoot = "ftp://servizi.thaiprincess.it/";
    internal const string FtpUser = "2961106@aruba.it";
    internal const string PasswordFile = "ftp-password.txt";
}

internal sealed class MainForm : Form
{
    private readonly Button uploadButton;
    private readonly Label statusLabel;
    public MainForm()
    {
        Text = "Thai Princess - Carica file";
        Width = 460;
        Height = 220;
        StartPosition = FormStartPosition.CenterScreen;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;

        uploadButton = new Button
        {
            Text = "Carica file",
            Width = 180,
            Height = 48,
            Anchor = AnchorStyles.None
        };
        uploadButton.Click += UploadButton_Click;

        statusLabel = new Label
        {
            Text = "Destinazione: FTP thaiprincess.it",
            AutoSize = true,
            TextAlign = System.Drawing.ContentAlignment.MiddleCenter,
            Anchor = AnchorStyles.None
        };

        var layout = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 1,
            RowCount = 3,
            Padding = new Padding(20)
        };
        layout.RowStyles.Add(new RowStyle(SizeType.Percent, 30));
        layout.RowStyles.Add(new RowStyle(SizeType.Percent, 40));
        layout.RowStyles.Add(new RowStyle(SizeType.Percent, 30));
        layout.Controls.Add(new Label { Text = "Caricamento sito", Dock = DockStyle.Fill, TextAlign = System.Drawing.ContentAlignment.MiddleCenter }, 0, 0);
        layout.Controls.Add(uploadButton, 0, 1);
        layout.Controls.Add(statusLabel, 0, 2);
        Controls.Add(layout);
    }

    private void UploadButton_Click(object? sender, EventArgs e)
    {
        using var dialog = new OpenFileDialog
        {
            Multiselect = true,
            Title = "Seleziona i file da caricare"
        };
        if (dialog.ShowDialog(this) != DialogResult.OK) return;

        try
        {
            var passwordPath = Path.Combine(AppContext.BaseDirectory, Program.PasswordFile);
            if (!File.Exists(passwordPath))
                throw new InvalidOperationException("Manca il file ftp-password.txt nella cartella dell'eseguibile.");

            var password = File.ReadAllText(passwordPath).Trim();
            if (string.IsNullOrEmpty(password))
                throw new InvalidOperationException("Il file ftp-password.txt e vuoto.");

            foreach (var source in dialog.FileNames)
            {
                UploadFile(source, password);
            }
            statusLabel.Text = $"Caricati {dialog.FileNames.Length} file";
            MessageBox.Show(this, "Caricamento completato.", "Operazione conclusa", MessageBoxButtons.OK, MessageBoxIcon.Information);
        }
        catch (Exception ex)
        {
            statusLabel.Text = "Errore di caricamento";
            MessageBox.Show(this, ex.Message, "Errore", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }

    internal static void UploadFile(string source, string password, string? remotePath = null)
    {
        var relativePath = (remotePath ?? Path.GetFileName(source)).Replace('\\', '/').TrimStart('/');
        var segments = relativePath.Split('/');
        EnsureRemoteDirectories(segments, password);

        var escapedPath = string.Join("/", segments.Select(Uri.EscapeDataString));
        var request = (FtpWebRequest)WebRequest.Create(Program.FtpRoot + escapedPath);
        request.Method = WebRequestMethods.Ftp.UploadFile;
        request.Credentials = new NetworkCredential(Program.FtpUser, password);
        request.UseBinary = true;
        request.UsePassive = true;
        request.KeepAlive = false;

        using (var input = File.OpenRead(source))
        using (var output = request.GetRequestStream())
            input.CopyTo(output);

        using var response = (FtpWebResponse)request.GetResponse();
        if (response.StatusCode != FtpStatusCode.ClosingData && response.StatusCode != FtpStatusCode.CommandOK)
            throw new IOException("FTP: " + response.StatusDescription);
    }

    // FTP non crea le cartelle intermedie da solo: le crea una a una, ignorando
    // l'errore "gia' esistente" (550) cosi' l'upload resta ripetibile.
    private static void EnsureRemoteDirectories(string[] segments, string password)
    {
        if (segments.Length <= 1) return;
        var accumulated = "";
        for (var i = 0; i < segments.Length - 1; i++)
        {
            accumulated += (i == 0 ? "" : "/") + Uri.EscapeDataString(segments[i]);
            var request = (FtpWebRequest)WebRequest.Create(Program.FtpRoot + accumulated);
            request.Method = WebRequestMethods.Ftp.MakeDirectory;
            request.Credentials = new NetworkCredential(Program.FtpUser, password);
            request.UsePassive = true;
            request.KeepAlive = false;
            try
            {
                using var response = (FtpWebResponse)request.GetResponse();
            }
            catch (WebException ex) when (ex.Response is FtpWebResponse { StatusCode: FtpStatusCode.ActionNotTakenFileUnavailable })
            {
                // Cartella gia' esistente: va bene cosi'.
            }
        }
    }
}
