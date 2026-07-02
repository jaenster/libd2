# libd2 from C#

No special build — P/Invoke the shared library from the `items-vX.Y.Z` GitHub
Release (`d2items.dll` / `libd2items.so` / `libd2items.dylib`). Put it next to your
executable or on the loader path. See the
[API reference](../../README.md#reference-api-the-items-package).

```csharp
using System;
using System.Runtime.InteropServices;

[StructLayout(LayoutKind.Sequential)]
struct D2ItemsDrop {
    public byte kind;
    [MarshalAs(UnmanagedType.ByValArray, SizeConst = 4)] public byte[] item_code;
    public byte quality;
    public ushort prefix_id, suffix_id;
    [MarshalAs(UnmanagedType.ByValArray, SizeConst = 3)] public ushort[] rare_prefix_ids;
    [MarshalAs(UnmanagedType.ByValArray, SizeConst = 3)] public ushort[] rare_suffix_ids;
    public byte sockets;
    public int quantity, item_level;
}

static class D2Items {
    const string L = "d2items"; // d2items.dll / libd2items.so / libd2items.dylib
    [DllImport(L)] public static extern IntPtr d2items_create();
    [DllImport(L)] public static extern void   d2items_destroy(IntPtr ctx);
    [DllImport(L)] public static extern int    d2items_roll(
        IntPtr ctx, uint seed, string tc, int mlvl, int mf,
        [Out] D2ItemsDrop[] outv, int cap);
}

class Program {
    static void Main() {
        var ctx = D2Items.d2items_create();
        var d = new D2ItemsDrop[16];
        int n = D2Items.d2items_roll(ctx, 12345, "Act 1 Equip A", 5, 0, d, 16);
        for (int i = 0; i < n && i < 16; i++)
            Console.WriteLine($"{System.Text.Encoding.ASCII.GetString(d[i].item_code)} ilvl={d[i].item_level}");
        D2Items.d2items_destroy(ctx);
    }
}
```
