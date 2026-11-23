namespace Murmur.Windows;

internal sealed class RecordingHud : Form
{
    private readonly Label status = new() { Dock = DockStyle.Fill, ForeColor = Color.White, TextAlign = ContentAlignment.MiddleLeft };
    private readonly ProgressBar level = new() { Dock = DockStyle.Bottom, Height = 6, Maximum = 100 };
    protected override bool ShowWithoutActivation => true;
    protected override CreateParams CreateParams { get { var p = base.CreateParams; p.ExStyle |= 0x08000000 | 0x80; return p; } }
    public RecordingHud(Action cancel)
    {
        Text = "Murmur Recording"; FormBorderStyle = FormBorderStyle.None; ShowInTaskbar = false; TopMost = true;
        BackColor = Color.FromArgb(24, 32, 48); Padding = new Padding(18, 12, 12, 12); Size = new Size(470, 84);
        Font = new Font("Segoe UI", 11);
        var stop = new Button { Text = "取消 / Cancel", Dock = DockStyle.Right, Width = 110, FlatStyle = FlatStyle.Flat, ForeColor = Color.White };
        stop.Click += (_, _) => cancel(); Controls.Add(status); Controls.Add(stop); Controls.Add(level);
    }
    public void UpdateStatus(string text, float value)
    {
        status.Text = text; level.Value = Math.Clamp((int)(value * 100), 0, 100);
        if (!Visible)
        {
            var area = Screen.FromPoint(Cursor.Position).WorkingArea;
            Location = new Point(area.Left + (area.Width - Width) / 2, area.Bottom - Height - 28); Show();
        }
    }
}
