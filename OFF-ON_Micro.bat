<# :
@echo off
start "" powershell -ExecutionPolicy Bypass -WindowStyle Hidden -Command "iex ([IO.File]::ReadAllText('%~f0'))"
exit /b
#>

# название микрофона
$micro = "Sonar - Microphone"
# ` - кнопка для активации микрофона
$PttKey = 0xC0
# Shift - доп кнопка, которая должна быть зажата для выхода из скрипта
$VkShift = 0x10

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class PttTray {
    [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vk);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
    [DllImport("ole32.dll")] static extern int PropVariantClear(ref PV pv);

    [StructLayout(LayoutKind.Sequential)] struct PK { public Guid g; public uint id; }
    [StructLayout(LayoutKind.Sequential)] struct PV { public ushort vt, a, b, c; public IntPtr p, q; }

    // COM calls go by vtable position, so only the methods up to the one we call are declared.
    // The stubs (void A();...) just keep the positions right; they are never called.
    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class Enumerator {}

    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IEnum { void EnumAudioEndpoints(int flow, int mask, out IColl c); }

    [ComImport, Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IColl { void GetCount(out uint n); void Item(uint i, out IDev d); }

    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IDev {
        void Activate(ref Guid iid, int ctx, IntPtr p, [MarshalAs(UnmanagedType.IUnknown)] out object o);
        void OpenPropertyStore(int access, out IProps s);
    }

    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IProps { void GetCount(out uint n); void GetAt(uint i, out PK k); void GetValue(ref PK k, out PV v); }

    [ComImport, Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IVol {
        void A(); void B(); void C(); void D(); void E(); void F(); void G(); void H(); void I(); void J(); void K();
        void SetMute([MarshalAs(UnmanagedType.Bool)] bool mute, ref Guid ctx);
    }

    static IVol vol;

    static string Name(IDev d) {
        IProps s; d.OpenPropertyStore(0, out s);
        var k = new PK { g = new Guid("a45c254e-df1c-4efd-8020-67d146a850e0"), id = 14 };   // PKEY_Device_FriendlyName
        PV v; s.GetValue(ref k, out v);
        string n = v.vt == 31 ? Marshal.PtrToStringUni(v.p) : "";   // 31 = VT_LPWSTR
        PropVariantClear(ref v);
        return n;
    }

    // Finds an active capture device whose name contains `part` and remembers it for SetMute.
    public static string Init(string part) {
        IColl c; ((IEnum)new Enumerator()).EnumAudioEndpoints(1, 1, out c);   // 1 = capture, 1 = active only
        uint n; c.GetCount(out n);
        string all = "";
        for (uint i = 0; i < n; i++) {
            IDev d; c.Item(i, out d);
            string name = Name(d);
            all += "\n  - " + name;
            if (name.IndexOf(part, StringComparison.OrdinalIgnoreCase) < 0) continue;
            object o; Guid iid = typeof(IVol).GUID;
            d.Activate(ref iid, 23, IntPtr.Zero, out o);   // 23 = CLSCTX_ALL
            vol = (IVol)o;
            return name;
        }
        throw new Exception("Microphone not found: '" + part + "'. Available devices:" + all);
    }

    public static void SetMute(bool m) { Guid g = Guid.Empty; vol.SetMute(m, ref g); }
}
'@

# Ошибка если не найден микрофон
try {
    $found = [PttTray]::Init($micro)
}
catch {
    $e = $_.Exception
    if ($e.InnerException) { $e = $e.InnerException }
    [void][System.Windows.Forms.MessageBox]::Show($e.Message, 'PTT', 'OK', 'Error')
    exit 1
}

# Иконка в трее
function New-DotIcon($color) {
    $bmp = New-Object System.Drawing.Bitmap 16, 16
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $brush = New-Object System.Drawing.SolidBrush $color
    $g.FillEllipse($brush, 1, 1, 14, 14)
    $g.Dispose(); $brush.Dispose()
    return [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
}
$iconOn = New-DotIcon ([System.Drawing.Color]::LimeGreen)
$iconOff = New-DotIcon ([System.Drawing.Color]::Gray)

$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = $iconOff
$tray.Text = 'PTT: mic OFF'
$tray.Visible = $true

# Уведомление при запуске
$tray.BalloonTipTitle = 'PTT started'
$tray.BalloonTipText = "Microphone: $found"
$tray.ShowBalloonTip(3000)

# Прячет окно консоли, когда иконка появилась
[void][PttTray]::ShowWindow([PttTray]::GetConsoleWindow(), 0)

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$exitItem = $menu.Items.Add('Close')
$exitItem.add_Click({ [System.Windows.Forms.Application]::Exit() })
$tray.ContextMenuStrip = $menu

$script:muted = $null

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 20
$timer.add_Tick({
    $pressed = ([PttTray]::GetAsyncKeyState($PttKey) -band 0x8000) -ne 0

    if ($script:muted -ne (-not $pressed)) {
        $script:muted = -not $pressed
        [PttTray]::SetMute($script:muted)
        if ($script:muted) {
            $tray.Icon = $iconOff
            $tray.Text = 'PTT: mic OFF'
        } else {
            $tray.Icon = $iconOn
            $tray.Text = 'PTT: mic ON'
        }
    }

    # комбинация для выхода: Shift+`
    if ($pressed -and ([PttTray]::GetAsyncKeyState($VkShift) -band 0x8000)) {
        [System.Windows.Forms.Application]::Exit()
    }
})
$timer.Start()

try {
    [System.Windows.Forms.Application]::Run()
}
finally {
    $timer.Stop()
    [PttTray]::SetMute($false)   # включение микрофона при выходе
    $tray.Visible = $false
    $tray.Dispose()
}