using System;
using System.Runtime.InteropServices;

namespace LibD2.ItemDraw;

/// <summary>The raw C entry points of d2itemdraw. Internal: the public surface is <see cref="ItemDrawer"/>.</summary>
internal static class Native
{
    private const string Lib = "d2itemdraw";

    /// <summary>ABI this binding was written against. Checked once on first use.</summary>
    internal const uint ExpectedAbi = 1;

    [StructLayout(LayoutKind.Sequential)]
    internal struct Options
    {
        public int HasViewer;
        public int ClassId;
        public int Level;
        public int Strength;
        public int Dexterity;
        public int Act;
    }

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    internal static extern uint d2itemdraw_abi_version();

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    internal static extern IntPtr d2itemdraw_alloc(UIntPtr len);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    internal static extern void d2itemdraw_free(IntPtr ptr, UIntPtr len);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    internal static extern IntPtr d2itemdraw_create();

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    internal static extern void d2itemdraw_destroy(IntPtr ctx);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int d2itemdraw_add_archive(IntPtr ctx, IntPtr bytes, UIntPtr len);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int d2itemdraw_add_file(IntPtr ctx, [MarshalAs(UnmanagedType.LPStr)] string name, byte[] bytes, UIntPtr len);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int d2itemdraw_text(IntPtr ctx, byte[] records, UIntPtr len, ref Options opts, int mode, byte[]? output, UIntPtr cap);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    internal static extern IntPtr d2itemdraw_icon(IntPtr ctx, byte[] records, UIntPtr len, ref Options opts, int background, int sockets);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    internal static extern IntPtr d2itemdraw_tooltip(IntPtr ctx, byte[] records, UIntPtr len, ref Options opts);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    internal static extern IntPtr d2itemdraw_card(IntPtr ctx, byte[] records, UIntPtr len, ref Options opts);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    internal static extern uint d2itemdraw_image_width(IntPtr img);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    internal static extern uint d2itemdraw_image_height(IntPtr img);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    internal static extern IntPtr d2itemdraw_image_rgba(IntPtr img);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    internal static extern IntPtr d2itemdraw_image_png(IntPtr img, out UIntPtr len);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    internal static extern void d2itemdraw_image_free(IntPtr img);
}
