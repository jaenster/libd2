using System;
using System.Runtime.InteropServices;

namespace LibD2.Drlg;

/// <summary>
/// The raw C entry points. Everything here is internal: the public surface of this package
/// deals in <see cref="Level"/>, <see cref="Room"/> and friends, never in handles.
/// </summary>
/// <remarks>
/// NuGet ships one native binary per RID under <c>runtimes/{rid}/native/</c>, so the runtime
/// resolves the right one and the library name below never needs a platform suffix.
/// </remarks>
internal static class Native
{
    private const string Lib = "d2drlg";

    /// <summary>ABI this binding was written against. Checked once on first use.</summary>
    internal const uint ExpectedAbi = 3;

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    internal static extern IntPtr d2drlg_ctx_create();

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    internal static extern void d2drlg_ctx_destroy(IntPtr ctx);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    internal static extern IntPtr d2drlg_gen_act(IntPtr ctx, uint seed, int difficulty, int actNo);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    internal static extern void d2drlg_act_free(IntPtr act);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int d2drlg_act_level_count(IntPtr act);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int d2drlg_act_level_id(IntPtr act, int levelIndex);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int d2drlg_act_level_drlg_type(IntPtr act, int levelIndex);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int d2drlg_act_level_placed(IntPtr act, int levelIndex);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int d2drlg_act_level_room_count(IntPtr act, int levelIndex);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int d2drlg_act_rooms(IntPtr act, int levelIndex, [Out] Room[] outRooms, int cap);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int d2drlg_act_level_origin(IntPtr act, int levelIndex, out int ox, out int oy);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int d2drlg_act_level_size(IntPtr act, int levelIndex, out int w, out int h);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int d2drlg_act_level_presets(IntPtr act, int levelIndex, [Out] PresetUnit[] outUnits, int cap);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int d2drlg_act_level_adjacents(IntPtr act, int levelIndex, [Out] Adjacent[] outAdj, int cap);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int d2drlg_act_level_collision(IntPtr act, int levelIndex, [Out] ushort[] outCells, int cap, out int w, out int h);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int d2drlg_level_name(IntPtr ctx, int levelId, [Out] byte[] buf, int cap);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int d2drlg_level_shrines(IntPtr ctx, uint seed, int difficulty, int levelId, [Out] Shrine[] outShrines, int cap);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int d2drlg_object_name(int txtFileNo, [Out] byte[] buf, int cap);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    internal static extern uint d2drlg_abi_version();
}
