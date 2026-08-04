# libd2 from C#

No special build — P/Invoke the shared library from the package's GitHub Release
(`d2drlg.dll` / `libd2drlg.so` / `libd2drlg.dylib`, etc.). Put it next to your
executable or on the loader path. See the
[API reference](c.md#reference-the-drlg-c-api).

## drlg — generate a map from a seed

```csharp
using System;
using System.Runtime.InteropServices;

[StructLayout(LayoutKind.Sequential)]
struct D2DrlgRoom { public int x, y, w, h, n_type, n_preset_type; }

static class D2Drlg {
    const string L = "d2drlg"; // d2drlg.dll / libd2drlg.so / libd2drlg.dylib
    [DllImport(L)] public static extern IntPtr d2drlg_ctx_create();
    [DllImport(L)] public static extern void   d2drlg_ctx_destroy(IntPtr ctx);
    [DllImport(L)] public static extern IntPtr d2drlg_gen_act(IntPtr ctx, uint seed, int diff, int act);
    [DllImport(L)] public static extern void   d2drlg_act_free(IntPtr act);
    [DllImport(L)] public static extern int    d2drlg_act_level_count(IntPtr act);
    [DllImport(L)] public static extern int    d2drlg_act_rooms(IntPtr act, int lvl, [Out] D2DrlgRoom[] outv, int cap);
}

class Program {
    static void Main() {
        var ctx = D2Drlg.d2drlg_ctx_create();
        var act = D2Drlg.d2drlg_gen_act(ctx, 305419896, 0, 0);   // seed, normal, Act I
        Console.WriteLine($"act I: {D2Drlg.d2drlg_act_level_count(act)} levels");
        var rooms = new D2DrlgRoom[128];
        int n = D2Drlg.d2drlg_act_rooms(act, 0, rooms, rooms.Length);
        Console.WriteLine($"level 0: {n} rooms; first {rooms[0].w}x{rooms[0].h} at ({rooms[0].x},{rooms[0].y})");
        D2Drlg.d2drlg_act_free(act);
        D2Drlg.d2drlg_ctx_destroy(ctx);
    }
}
```

## items — roll a drop

```csharp
[StructLayout(LayoutKind.Sequential)]
struct D2ItemDrop {
    public byte kind;
    [MarshalAs(UnmanagedType.ByValArray, SizeConst = 4)] public byte[] item_code;
    public byte quality;
    public ushort prefix_id, suffix_id;
    [MarshalAs(UnmanagedType.ByValArray, SizeConst = 3)] public ushort[] rare_prefix_ids;
    [MarshalAs(UnmanagedType.ByValArray, SizeConst = 3)] public ushort[] rare_suffix_ids;
    public ushort rare_prefix_name, rare_suffix_name;
    public ushort unique_id, set_id, quality_id, low_quality_id, auto_prefix_id;
    public byte sockets, ethereal;
    public int quantity, item_level;
    public uint item_seed;
}
[DllImport("d2item")] static extern IntPtr d2item_create();
[DllImport("d2item")] static extern int d2item_roll(IntPtr c, uint seed, string tc, int mlvl, int mf, [Out] D2ItemDrop[] o, int cap);
```
