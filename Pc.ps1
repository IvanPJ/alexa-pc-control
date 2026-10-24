# Pc.ps1 - Windows side of Alexa PC Control: displays, audio, media keys and windows.
#
# Everything goes through documented Win32 APIs compiled on the fly with Add-Type, so there is
# nothing to install and nothing needs administrator rights:
#   displays  CCD API (QueryDisplayConfig / SetDisplayConfig): list screens, extend, pick the
#             primary one, snapshot and restore the layout
#   audio     Core Audio (IMMDeviceEnumerator, IAudioEndpointVolume) plus IPolicyConfig, the
#             interface the Sound control panel itself uses to change the default output
#   input     keybd_event media keys, window lookup and placement
#
# Dot-sourced by Agente.ps1 and Configurar.ps1.

if (-not ('Apc.Display' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

namespace Apc {

public class Monitor {
    public string Name;          // EDID friendly name, e.g. "LG TV SSCR2"
    public string DevicePath;    // stable id of the connector + monitor
    public bool Available;       // plugged in (and on, for most TVs)
    public bool Active;          // part of the desktop right now
    public bool Primary;
    public int X, Y, Width, Height;
}

public class AudioDevice {
    public string Id;
    public string Name;
    public bool IsDefault;
}

public static class Display {
    [StructLayout(LayoutKind.Sequential)] public struct LUID { public uint Low; public int High; }
    [StructLayout(LayoutKind.Sequential)] public struct RATIONAL { public uint Num; public uint Den; }

    [StructLayout(LayoutKind.Sequential)]
    public struct PATH_SOURCE { public LUID adapterId; public uint id; public uint modeInfoIdx; public uint statusFlags; }

    [StructLayout(LayoutKind.Sequential)]
    public struct PATH_TARGET {
        public LUID adapterId; public uint id; public uint modeInfoIdx; public uint outputTechnology;
        public uint rotation; public uint scaling; public RATIONAL refreshRate; public uint scanLineOrdering;
        public int targetAvailable; public uint statusFlags;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct PATH { public PATH_SOURCE source; public PATH_TARGET target; public uint flags; }

    [StructLayout(LayoutKind.Sequential)]
    public struct SOURCE_MODE { public uint width; public uint height; public uint pixelFormat; public int x; public int y; }

    // DISPLAYCONFIG_MODE_INFO: 16-byte header + a 48-byte union. Only the source mode is read;
    // the struct is blittable, so target and desktop modes round-trip untouched.
    [StructLayout(LayoutKind.Explicit, Size = 64)]
    public struct MODE {
        [FieldOffset(0)] public uint infoType;
        [FieldOffset(4)] public uint id;
        [FieldOffset(8)] public LUID adapterId;
        [FieldOffset(16)] public SOURCE_MODE sourceMode;
        [FieldOffset(56)] public ulong tail;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct INFO_HEADER { public uint type; public uint size; public LUID adapterId; public uint id; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct TARGET_NAME {
        public INFO_HEADER header; public uint flags; public uint outputTechnology;
        public ushort edidManufactureId; public ushort edidProductCodeId; public uint connectorInstance;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string monitorFriendlyDeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string monitorDevicePath;
    }

    const uint QDC_ALL_PATHS = 1, QDC_ONLY_ACTIVE_PATHS = 2;
    const uint SDC_TOPOLOGY_EXTEND = 4, SDC_USE_SUPPLIED_DISPLAY_CONFIG = 0x20, SDC_APPLY = 0x80;
    const uint SDC_SAVE_TO_DATABASE = 0x200, SDC_ALLOW_CHANGES = 0x400;
    const uint PATH_ACTIVE = 1, MODE_SOURCE = 1, MODE_IDX_INVALID = 0xFFFFFFFF, GET_TARGET_NAME = 2;

    [DllImport("user32.dll")] static extern int GetDisplayConfigBufferSizes(uint flags, out uint numPaths, out uint numModes);
    [DllImport("user32.dll")] static extern int QueryDisplayConfig(uint flags, ref uint numPaths, [Out] PATH[] paths, ref uint numModes, [Out] MODE[] modes, IntPtr topology);
    [DllImport("user32.dll")] static extern int SetDisplayConfig(uint numPaths, [In] PATH[] paths, uint numModes, [In] MODE[] modes, uint flags);
    [DllImport("user32.dll")] static extern int DisplayConfigGetDeviceInfo(ref TARGET_NAME name);

    static void Query(uint flags, out PATH[] paths, out MODE[] modes) {
        for (int attempt = 0; ; attempt++) {
            uint np, nm;
            int rc = GetDisplayConfigBufferSizes(flags, out np, out nm);
            if (rc != 0) throw new InvalidOperationException("GetDisplayConfigBufferSizes " + rc);
            paths = new PATH[np]; modes = new MODE[nm];
            rc = QueryDisplayConfig(flags, ref np, paths, ref nm, modes, IntPtr.Zero);
            if (rc == 122 && attempt < 3) continue;   // ERROR_INSUFFICIENT_BUFFER: a screen came or went
            if (rc != 0) throw new InvalidOperationException("QueryDisplayConfig " + rc);
            Array.Resize(ref paths, (int)np); Array.Resize(ref modes, (int)nm);
            return;
        }
    }

    static TARGET_NAME TargetName(LUID adapter, uint id) {
        TARGET_NAME n = new TARGET_NAME();
        n.header.type = GET_TARGET_NAME;
        n.header.size = (uint)Marshal.SizeOf(typeof(TARGET_NAME));
        n.header.adapterId = adapter; n.header.id = id;
        DisplayConfigGetDeviceInfo(ref n);
        return n;
    }

    static string Key(LUID a, uint id) { return a.High + ":" + a.Low + ":" + id; }

    static bool SameMonitor(TARGET_NAME n, string devicePath) {
        return !string.IsNullOrEmpty(devicePath) && string.Equals(n.monitorDevicePath, devicePath, StringComparison.OrdinalIgnoreCase);
    }

    public static List<Monitor> List() {
        PATH[] paths; MODE[] modes;
        Query(QDC_ALL_PATHS, out paths, out modes);
        PATH[] activePaths; MODE[] activeModes;
        Query(QDC_ONLY_ACTIVE_PATHS, out activePaths, out activeModes);

        Dictionary<string, Monitor> byTarget = new Dictionary<string, Monitor>();
        List<Monitor> result = new List<Monitor>();
        foreach (PATH p in paths) {
            string key = Key(p.target.adapterId, p.target.id);
            if (byTarget.ContainsKey(key)) {
                if (p.target.targetAvailable != 0) byTarget[key].Available = true;
                continue;
            }
            TARGET_NAME n = TargetName(p.target.adapterId, p.target.id);
            if (string.IsNullOrEmpty(n.monitorDevicePath)) continue;
            Monitor m = new Monitor();
            m.Name = string.IsNullOrEmpty(n.monitorFriendlyDeviceName) ? "Tela " + (result.Count + 1) : n.monitorFriendlyDeviceName;
            m.DevicePath = n.monitorDevicePath;
            m.Available = p.target.targetAvailable != 0;
            byTarget[key] = m; result.Add(m);
        }
        foreach (PATH p in activePaths) {
            Monitor m;
            if (!byTarget.TryGetValue(Key(p.target.adapterId, p.target.id), out m)) continue;
            m.Active = true; m.Available = true;
            if (p.source.modeInfoIdx < activeModes.Length) {
                SOURCE_MODE s = activeModes[p.source.modeInfoIdx].sourceMode;
                m.X = s.x; m.Y = s.y; m.Width = (int)s.width; m.Height = (int)s.height;
                m.Primary = s.x == 0 && s.y == 0;
            }
        }
        // a monitor that is unplugged and never was active has no stable name worth showing
        result.RemoveAll(delegate (Monitor m) { return !m.Available && !m.Active && m.Name.StartsWith("Tela "); });
        return result;
    }

    // ------------------------------------------------------------ snapshot / restore

    public static string Snapshot() {
        PATH[] paths; MODE[] modes;
        Query(QDC_ONLY_ACTIVE_PATHS, out paths, out modes);
        using (MemoryStream ms = new MemoryStream())
        using (BinaryWriter w = new BinaryWriter(ms)) {
            w.Write(paths.Length); w.Write(modes.Length);
            foreach (PATH p in paths) w.Write(ToBytes(p));
            foreach (MODE m in modes) w.Write(ToBytes(m));
            w.Flush();
            return Convert.ToBase64String(ms.ToArray());
        }
    }

    // Applies a Snapshot() exactly. Fails (non-zero) after a reboot or driver update, because
    // adapter ids are only valid for the current boot; the caller falls back to Deactivate/SetPrimary.
    public static int Restore(string snapshot) {
        byte[] data = Convert.FromBase64String(snapshot);
        using (BinaryReader r = new BinaryReader(new MemoryStream(data))) {
            int np = r.ReadInt32(), nm = r.ReadInt32();
            PATH[] paths = new PATH[np]; MODE[] modes = new MODE[nm];
            for (int i = 0; i < np; i++) paths[i] = FromBytes<PATH>(r.ReadBytes(Marshal.SizeOf(typeof(PATH))));
            for (int i = 0; i < nm; i++) modes[i] = FromBytes<MODE>(r.ReadBytes(Marshal.SizeOf(typeof(MODE))));
            return Apply(paths, modes);
        }
    }

    static byte[] ToBytes<T>(T value) {
        int size = Marshal.SizeOf(typeof(T));
        byte[] buf = new byte[size];
        IntPtr ptr = Marshal.AllocHGlobal(size);
        try { Marshal.StructureToPtr(value, ptr, false); Marshal.Copy(ptr, buf, 0, size); }
        finally { Marshal.FreeHGlobal(ptr); }
        return buf;
    }

    static T FromBytes<T>(byte[] buf) {
        IntPtr ptr = Marshal.AllocHGlobal(buf.Length);
        try { Marshal.Copy(buf, 0, ptr, buf.Length); return (T)Marshal.PtrToStructure(ptr, typeof(T)); }
        finally { Marshal.FreeHGlobal(ptr); }
    }

    static int Apply(PATH[] paths, MODE[] modes) {
        return SetDisplayConfig((uint)paths.Length, paths, (uint)modes.Length, modes,
            SDC_APPLY | SDC_USE_SUPPLIED_DISPLAY_CONFIG | SDC_SAVE_TO_DATABASE | SDC_ALLOW_CHANGES);
    }

    // ------------------------------------------------------------ changes

    // Same as Win+P "Extend": every connected screen joins the desktop.
    public static int Extend() {
        return SetDisplayConfig(0, null, 0, null, SDC_APPLY | SDC_TOPOLOGY_EXTEND);
    }

    // The primary screen is the one whose desktop starts at (0,0): shift every screen so the
    // chosen one lands there. Returns 0 when done or already primary, -1 when it is not active.
    public static int SetPrimary(string devicePath) {
        PATH[] paths; MODE[] modes;
        Query(QDC_ONLY_ACTIVE_PATHS, out paths, out modes);
        int idx = FindSourceMode(paths, devicePath);
        if (idx < 0) return -1;
        int dx = modes[idx].sourceMode.x, dy = modes[idx].sourceMode.y;
        if (dx == 0 && dy == 0) return 0;
        for (int i = 0; i < modes.Length; i++) {
            if (modes[i].infoType != MODE_SOURCE) continue;
            modes[i].sourceMode.x -= dx; modes[i].sourceMode.y -= dy;
        }
        return Apply(paths, modes);
    }

    // Takes one screen out of the desktop (like unchecking it), then makes primaryPath the
    // primary screen when given. Returns 0 when done or already off.
    public static int Deactivate(string devicePath, string primaryPath) {
        PATH[] paths; MODE[] modes;
        Query(QDC_ONLY_ACTIVE_PATHS, out paths, out modes);
        List<PATH> keep = new List<PATH>();
        foreach (PATH p in paths) if (!SameMonitor(TargetName(p.target.adapterId, p.target.id), devicePath)) keep.Add(p);
        if (keep.Count == paths.Length) return 0;
        if (keep.Count == 0) return -2;   // never turn off the last screen

        // keep only the modes still referenced, re-indexed
        List<MODE> newModes = new List<MODE>();
        Dictionary<uint, uint> remap = new Dictionary<uint, uint>();
        PATH[] kept = keep.ToArray();
        for (int i = 0; i < kept.Length; i++) {
            kept[i].source.modeInfoIdx = Remap(kept[i].source.modeInfoIdx, modes, newModes, remap);
            kept[i].target.modeInfoIdx = Remap(kept[i].target.modeInfoIdx, modes, newModes, remap);
        }
        MODE[] outModes = newModes.ToArray();

        int primary = FindSourceMode(kept, primaryPath);
        if (primary < 0) {   // the left-most remaining screen becomes the primary one
            for (int i = 0; i < outModes.Length; i++) {
                if (outModes[i].infoType != MODE_SOURCE) continue;
                if (primary < 0 || outModes[i].sourceMode.x < outModes[primary].sourceMode.x) primary = i;
            }
        }
        if (primary >= 0) {
            int dx = outModes[primary].sourceMode.x, dy = outModes[primary].sourceMode.y;
            for (int i = 0; i < outModes.Length; i++) {
                if (outModes[i].infoType != MODE_SOURCE) continue;
                outModes[i].sourceMode.x -= dx; outModes[i].sourceMode.y -= dy;
            }
        }
        return Apply(kept, outModes);
    }

    static uint Remap(uint idx, MODE[] modes, List<MODE> newModes, Dictionary<uint, uint> remap) {
        if (idx == MODE_IDX_INVALID || idx >= modes.Length) return idx;
        uint mapped;
        if (!remap.TryGetValue(idx, out mapped)) { mapped = (uint)newModes.Count; newModes.Add(modes[idx]); remap[idx] = mapped; }
        return mapped;
    }

    static int FindSourceMode(PATH[] paths, string devicePath) {
        foreach (PATH p in paths) {
            if (!SameMonitor(TargetName(p.target.adapterId, p.target.id), devicePath)) continue;
            if (p.source.modeInfoIdx != MODE_IDX_INVALID) return (int)p.source.modeInfoIdx;
        }
        return -1;
    }
}

// ---------------------------------------------------------------- audio

[ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDeviceEnumerator {
    [PreserveSig] int EnumAudioEndpoints(int dataFlow, int stateMask, out IMMDeviceCollection devices);
    [PreserveSig] int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice device);
    [PreserveSig] int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IMMDevice device);
}

[ComImport, Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDeviceCollection {
    [PreserveSig] int GetCount(out int count);
    [PreserveSig] int Item(int index, out IMMDevice device);
}

[ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDevice {
    [PreserveSig] int Activate(ref Guid iid, int clsCtx, IntPtr activationParams, [MarshalAs(UnmanagedType.IUnknown)] out object iface);
    [PreserveSig] int OpenPropertyStore(int access, out IPropertyStore store);
    [PreserveSig] int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
}

[StructLayout(LayoutKind.Sequential)] struct PROPERTYKEY { public Guid fmtid; public int pid; }

[StructLayout(LayoutKind.Explicit, Size = 24)]
struct PROPVARIANT { [FieldOffset(0)] public ushort vt; [FieldOffset(8)] public IntPtr pointer; }

[ComImport, Guid("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IPropertyStore {
    [PreserveSig] int GetCount(out int count);
    [PreserveSig] int GetAt(int index, out PROPERTYKEY key);
    [PreserveSig] int GetValue(ref PROPERTYKEY key, out PROPVARIANT value);
}

[ComImport, Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAudioEndpointVolume {
    [PreserveSig] int RegisterControlChangeNotify(IntPtr notify);
    [PreserveSig] int UnregisterControlChangeNotify(IntPtr notify);
    [PreserveSig] int GetChannelCount(out int count);
    [PreserveSig] int SetMasterVolumeLevel(float levelDb, ref Guid context);
    [PreserveSig] int SetMasterVolumeLevelScalar(float level, ref Guid context);
    [PreserveSig] int GetMasterVolumeLevel(out float levelDb);
    [PreserveSig] int GetMasterVolumeLevelScalar(out float level);
    [PreserveSig] int SetChannelVolumeLevel(uint channel, float levelDb, ref Guid context);
    [PreserveSig] int SetChannelVolumeLevelScalar(uint channel, float level, ref Guid context);
    [PreserveSig] int GetChannelVolumeLevel(uint channel, out float levelDb);
    [PreserveSig] int GetChannelVolumeLevelScalar(uint channel, out float level);
    [PreserveSig] int SetMute([MarshalAs(UnmanagedType.Bool)] bool mute, ref Guid context);
    [PreserveSig] int GetMute([MarshalAs(UnmanagedType.Bool)] out bool mute);
}

// Undocumented but stable since Windows 7: what the Sound control panel calls to set the default device.
[ComImport, Guid("f8679f50-850a-41cf-9c72-430f290290c8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IPolicyConfig {
    [PreserveSig] int GetMixFormat([MarshalAs(UnmanagedType.LPWStr)] string id, IntPtr format);
    [PreserveSig] int GetDeviceFormat([MarshalAs(UnmanagedType.LPWStr)] string id, int isDefault, IntPtr format);
    [PreserveSig] int ResetDeviceFormat([MarshalAs(UnmanagedType.LPWStr)] string id);
    [PreserveSig] int SetDeviceFormat([MarshalAs(UnmanagedType.LPWStr)] string id, IntPtr endpointFormat, IntPtr mixFormat);
    [PreserveSig] int GetProcessingPeriod([MarshalAs(UnmanagedType.LPWStr)] string id, int isDefault, IntPtr defaultPeriod, IntPtr minPeriod);
    [PreserveSig] int SetProcessingPeriod([MarshalAs(UnmanagedType.LPWStr)] string id, IntPtr period);
    [PreserveSig] int GetShareMode([MarshalAs(UnmanagedType.LPWStr)] string id, IntPtr mode);
    [PreserveSig] int SetShareMode([MarshalAs(UnmanagedType.LPWStr)] string id, IntPtr mode);
    [PreserveSig] int GetPropertyValue([MarshalAs(UnmanagedType.LPWStr)] string id, IntPtr key, IntPtr value);
    [PreserveSig] int SetPropertyValue([MarshalAs(UnmanagedType.LPWStr)] string id, IntPtr key, IntPtr value);
    [PreserveSig] int SetDefaultEndpoint([MarshalAs(UnmanagedType.LPWStr)] string id, int role);
    [PreserveSig] int SetEndpointVisibility([MarshalAs(UnmanagedType.LPWStr)] string id, int visible);
}

[ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class MMDeviceEnumeratorClass { }
[ComImport, Guid("870af99c-171d-4f9e-af0d-e63df40c2bc9")] class PolicyConfigClass { }

public static class Audio {
    const int RENDER = 0, ACTIVE = 1, ROLE_MULTIMEDIA = 1, CLSCTX_ALL = 23, VT_LPWSTR = 31;

    [DllImport("ole32.dll")] static extern int PropVariantClear(ref PROPVARIANT pv);

    static IMMDeviceEnumerator Enumerator() { return (IMMDeviceEnumerator)new MMDeviceEnumeratorClass(); }

    static void Check(int hr, string what) { if (hr < 0) throw new InvalidOperationException(what + " 0x" + hr.ToString("X8")); }

    static string FriendlyName(IMMDevice dev) {
        IPropertyStore store;
        if (dev.OpenPropertyStore(0, out store) != 0) return null;
        PROPERTYKEY key = new PROPERTYKEY();
        key.fmtid = new Guid("a45c254e-df1c-4efd-8020-67d146a850e0"); key.pid = 14;   // PKEY_Device_FriendlyName
        PROPVARIANT pv;
        if (store.GetValue(ref key, out pv) != 0) return null;
        string name = pv.vt == VT_LPWSTR ? Marshal.PtrToStringUni(pv.pointer) : null;
        PropVariantClear(ref pv);
        return name;
    }

    // role: 0 console (system sounds), 1 multimedia (games, music), 2 communications (voice chat)
    public static string DefaultId(int role) {
        IMMDevice dev;
        if (Enumerator().GetDefaultAudioEndpoint(RENDER, role, out dev) != 0) return null;
        string id; dev.GetId(out id);
        return id;
    }
    public static string DefaultId() { return DefaultId(ROLE_MULTIMEDIA); }

    public static List<AudioDevice> List() {
        IMMDeviceCollection col;
        Check(Enumerator().EnumAudioEndpoints(RENDER, ACTIVE, out col), "EnumAudioEndpoints");
        int count; col.GetCount(out count);
        string def = DefaultId();
        List<AudioDevice> result = new List<AudioDevice>();
        for (int i = 0; i < count; i++) {
            IMMDevice dev; col.Item(i, out dev);
            AudioDevice d = new AudioDevice();
            dev.GetId(out d.Id);
            d.Name = FriendlyName(dev) ?? d.Id;
            d.IsDefault = d.Id == def;
            result.Add(d);
        }
        return result;
    }

    // Default for every role (console, multimedia, communications), like "Set as Default Device".
    public static void SetDefault(string id) { for (int role = 0; role < 3; role++) SetDefault(id, role); }
    public static void SetDefault(string id, int role) {
        IPolicyConfig policy = (IPolicyConfig)new PolicyConfigClass();
        Check(policy.SetDefaultEndpoint(id, role), "SetDefaultEndpoint");
    }

    static IAudioEndpointVolume Volume() {
        IMMDevice dev;
        Check(Enumerator().GetDefaultAudioEndpoint(RENDER, ROLE_MULTIMEDIA, out dev), "GetDefaultAudioEndpoint");
        Guid iid = typeof(IAudioEndpointVolume).GUID;
        object o;
        Check(dev.Activate(ref iid, CLSCTX_ALL, IntPtr.Zero, out o), "Activate");
        return (IAudioEndpointVolume)o;
    }

    // 0..100 on the default output. S_FALSE (1) means "already like that" and is not an error.
    public static int GetVolume() { float v; Check(Volume().GetMasterVolumeLevelScalar(out v), "GetVolume"); return (int)Math.Round(v * 100); }
    public static void SetVolume(int percent) {
        Guid ctx = Guid.Empty;
        Check(Volume().SetMasterVolumeLevelScalar(Math.Max(0, Math.Min(100, percent)) / 100f, ref ctx), "SetVolume");
    }
    public static bool GetMute() { bool m; Check(Volume().GetMute(out m), "GetMute"); return m; }
    public static void SetMute(bool mute) { Guid ctx = Guid.Empty; Check(Volume().SetMute(mute, ref ctx), "SetMute"); }
}

// ---------------------------------------------------------------- keys and windows

public static class Input {
    [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    public const byte NEXT = 0xB0, PREVIOUS = 0xB1, STOP = 0xB2, PLAY_PAUSE = 0xB3;

    public static void Press(byte vk) {
        keybd_event(vk, 0, 1, UIntPtr.Zero);       // KEYEVENTF_EXTENDEDKEY
        keybd_event(vk, 0, 1 | 2, UIntPtr.Zero);   // + KEYEVENTF_KEYUP
    }
}

public static class Windows {
    delegate bool EnumProc(IntPtr hwnd, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc proc, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr hwnd, StringBuilder text, int max);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr hwnd, int cmd);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }

    // Physical pixels everywhere, same as the display API.
    public static void UsePhysicalPixels() { SetProcessDPIAware(); }

    public static IntPtr Find(string titlePart) {
        IntPtr found = IntPtr.Zero;
        EnumWindows(delegate (IntPtr h, IntPtr l) {
            if (!IsWindowVisible(h)) return true;
            StringBuilder sb = new StringBuilder(256);
            GetWindowText(h, sb, 256);
            if (sb.ToString().IndexOf(titlePart, StringComparison.OrdinalIgnoreCase) >= 0) { found = h; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    public static bool IsInside(IntPtr hwnd, int x, int y, int width, int height) {
        RECT r;
        if (!GetWindowRect(hwnd, out r)) return false;
        int cx = (r.Left + r.Right) / 2, cy = (r.Top + r.Bottom) / 2;
        return cx >= x && cx < x + width && cy >= y && cy < y + height;
    }

    // Restore, move onto the screen at (x,y,width,height), maximize there and bring to front.
    public static void MoveTo(IntPtr hwnd, int x, int y, int width, int height) {
        ShowWindow(hwnd, 9);   // SW_RESTORE
        SetWindowPos(hwnd, IntPtr.Zero, x, y, width, height, 0x0004 | 0x0040);   // NOZORDER | SHOWWINDOW
        ShowWindow(hwnd, 3);   // SW_MAXIMIZE
        SetForegroundWindow(hwnd);
    }
}
}
'@
}

function Get-ApcMonitors { return @([Apc.Display]::List()) }

function Find-ApcMonitor([string]$DevicePath, [string]$Name) {
    $all = Get-ApcMonitors
    $m = $all | Where-Object { $DevicePath -and $_.DevicePath -eq $DevicePath } | Select-Object -First 1
    if (-not $m -and $Name) { $m = $all | Where-Object { $_.Name -eq $Name } | Select-Object -First 1 }
    return $m
}

function Get-ApcAudioDevices { return @([Apc.Audio]::List()) }

function Find-ApcAudioDevice([string]$Id, [string]$Name) {
    $all = Get-ApcAudioDevices
    $d = $all | Where-Object { $Id -and $_.Id -eq $Id } | Select-Object -First 1
    if (-not $d -and $Name) { $d = $all | Where-Object { $_.Name -eq $Name } | Select-Object -First 1 }
    return $d
}

# Audio output that most likely belongs to a screen: HDMI audio is usually named after the monitor,
# e.g. "LG TV SSCR2 (NVIDIA High Definition Audio)" for the screen "LG TV SSCR2".
function Find-ApcAudioForMonitor([string]$MonitorName) {
    if (-not $MonitorName) { return $null }
    return Get-ApcAudioDevices | Where-Object { $_.Name -like ('*' + $MonitorName + '*') } | Select-Object -First 1
}
