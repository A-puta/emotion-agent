$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

[ComImport, Guid("43826d1e-e718-42ee-bc55-a1e261c37bfe"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IShellItem { }

[ComImport, Guid("b63ea76d-1f85-456f-a19c-48159efa858b"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IShellItemArray { }

[ComImport, Guid("2e941141-7f97-4756-ba1d-9decde894a3d"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IApplicationActivationManager {
    int ActivateApplication([MarshalAs(UnmanagedType.LPWStr)] string aumid,
                            [MarshalAs(UnmanagedType.LPWStr)] string args,
                            int options, out uint pid);
    int ActivateForFile([MarshalAs(UnmanagedType.LPWStr)] string aumid,
                        [MarshalAs(UnmanagedType.Interface)] IShellItemArray items,
                        [MarshalAs(UnmanagedType.LPWStr)] string verb,
                        out uint pid);
}

public static class MediaLauncher {
    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
    static extern void SHCreateItemFromParsingName(string path, IntPtr pbc,
        ref Guid riid, [MarshalAs(UnmanagedType.Interface)] out IShellItem item);

    [DllImport("shell32.dll", PreserveSig = false)]
    static extern void SHCreateShellItemArrayFromShellItem(IShellItem item,
        ref Guid riid, [MarshalAs(UnmanagedType.Interface)] out IShellItemArray array);

    public static uint Open(string aumid, string file) {
        var iidItem = new Guid("43826d1e-e718-42ee-bc55-a1e261c37bfe");
        IShellItem si;
        SHCreateItemFromParsingName(file, IntPtr.Zero, ref iidItem, out si);
        var iidArr = new Guid("b63ea76d-1f85-456f-a19c-48159efa858b");
        IShellItemArray sia;
        SHCreateShellItemArrayFromShellItem(si, ref iidArr, out sia);
        var clsid = new Guid("45BA127D-10A8-46EA-8AB7-56EA9078943C");
        var mgr = (IApplicationActivationManager)Activator.CreateInstance(Type.GetTypeFromCLSID(clsid));
        uint pid;
        mgr.ActivateForFile(aumid, sia, "open", out pid);
        return pid;
    }
}
'@

$file = $args[0]
$pid2 = [MediaLauncher]::Open('Microsoft.ZuneMusic_8wekyb3d8bbwe!Microsoft.ZuneMusic', $file)
"activated pid=$pid2"
