$micro   = "Sonar - Microphone"   # название микрофона
$PttKey  = 0xC0                   # ` - кнопка для активации микрофона
$VkShift = 0x10                   # Shift - доп кнопка, которая должна быть зажата для выхода из скрипта
$VkCtrl  = 0x11

Add-Type -AssemblyName System.Windows.Forms, System.Drawing

# Any startup error -> message box + log in %TEMP%\ptt-error.log
$ErrorActionPreference = 'Stop'
trap {
    $msg = $_.Exception.ToString()
    try { Set-Content -Path (Join-Path $env:TEMP 'ptt-error.log') -Value $msg -Encoding UTF8 } catch {}
    [void][System.Windows.Forms.MessageBox]::Show($msg, 'PTT: error', 'OK', 'Error')
    exit 1
}

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class PttTray {
    [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vk);
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("ole32.dll")] static extern int PropVariantClear(ref PropVariant pv);

    [StructLayout(LayoutKind.Sequential)]
    struct PropertyKey { public Guid fmtid; public uint pid; }

    [StructLayout(LayoutKind.Sequential)]
    struct PropVariant { public ushort vt; public ushort r1; public ushort r2; public ushort r3; public IntPtr p; public IntPtr p2; }

    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    class MMDeviceEnumerator {}

    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceEnumerator {
        int EnumAudioEndpoints(int flow, int stateMask, out IMMDeviceCollection devs);
        int GetDefaultAudioEndpoint(int flow, int role, out IMMDevice dev);
    }

    [ComImport, Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceCollection {
        int GetCount(out uint count);
        int Item(uint i, out IMMDevice dev);
    }

    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDevice {
        int Activate(ref Guid iid, int ctx, IntPtr p, [MarshalAs(UnmanagedType.IUnknown)] out object o);
        int OpenPropertyStore(int access, out IPropertyStore store);
        int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
        int GetState(out int state);
    }

    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IPropertyStore {
        int GetCount(out uint count);
        int GetAt(uint i, out PropertyKey key);
        int GetValue(ref PropertyKey key, out PropVariant val);
        int SetValue(ref PropertyKey key, ref PropVariant val);
        int Commit();
    }

    [ComImport, Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioEndpointVolume {
        int RegisterControlChangeNotify(IntPtr p);
        int UnregisterControlChangeNotify(IntPtr p);
        int GetChannelCount(out uint c);
        int SetMasterVolumeLevel(float l, ref Guid g);
        int SetMasterVolumeLevelScalar(float l, ref Guid g);
        int GetMasterVolumeLevel(out float l);
        int GetMasterVolumeLevelScalar(out float l);
        int SetChannelVolumeLevel(uint n, float l, ref Guid g);
        int SetChannelVolumeLevelScalar(uint n, float l, ref Guid g);
        int GetChannelVolumeLevel(uint n, out float l);
        int GetChannelVolumeLevelScalar(uint n, out float l);
        int SetMute([MarshalAs(UnmanagedType.Bool)] bool mute, ref Guid g);
        int GetMute([MarshalAs(UnmanagedType.Bool)] out bool mute);
    }

    static IAudioEndpointVolume vol;

    static string FriendlyName(IMMDevice dev) {
        IPropertyStore store;
        dev.OpenPropertyStore(0, out store);
        PropertyKey key = new PropertyKey();
        key.fmtid = new Guid("a45c254e-df1c-4efd-8020-67d146a850e0");   // PKEY_Device_FriendlyName
        key.pid = 14;
        PropVariant pv;
        store.GetValue(ref key, out pv);
        string name = (pv.vt == 31 && pv.p != IntPtr.Zero) ? Marshal.PtrToStringUni(pv.p) : "";
        PropVariantClear(ref pv);
        return name;
    }

    public static string Init(string part) {
        var en = (IMMDeviceEnumerator)new MMDeviceEnumerator();
        IMMDeviceCollection col;
        en.EnumAudioEndpoints(1, 1, out col);   // 1 = capture devices, 1 = active only
        uint n;
        col.GetCount(out n);
        string all = "";
        for (uint i = 0; i < n; i++) {
            IMMDevice dev;
            col.Item(i, out dev);
            string name = FriendlyName(dev);
            all += "\n  - " + name;
            if (name.IndexOf(part, StringComparison.OrdinalIgnoreCase) >= 0) {
                Guid iid = typeof(IAudioEndpointVolume).GUID;
                object o;
                dev.Activate(ref iid, 23, IntPtr.Zero, out o);
                vol = (IAudioEndpointVolume)o;
                return name;
            }
        }
        throw new Exception("Microphone not found: '" + part + "'. Available devices:" + all);
    }

    public static void SetMute(bool m) {
        Guid g = Guid.Empty;
        vol.SetMute(m, ref g);
    }
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
$iconOn  = New-DotIcon ([System.Drawing.Color]::LimeGreen)
$iconOff = New-DotIcon ([System.Drawing.Color]::Gray)

$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = $iconOff
$tray.Text = 'PTT: mic OFF'
$tray.Visible = $true

# Уведомление при запуске
$tray.BalloonTipTitle = 'PTT started'
$tray.BalloonTipText  = "Microphone: $found"
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

    # комбинация для выхода: Ctrl+Shift+`
    if ($pressed -and ([PttTray]::GetAsyncKeyState($VkShift) -band 0x8000) -and ([PttTray]::GetAsyncKeyState($VkCtrl) -band 0x8000)) {
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