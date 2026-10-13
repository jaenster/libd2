//! bindgen: the raw language bindings of every libd2 C ABI, generated from the C headers.
//!
//!   bindgen <repo root>           write the generated files
//!   bindgen <repo root> --check   fail (exit 1) when any generated file differs from what is on disk
//!
//! For each library in `libraries` it reads `packages/<pkg>/include/<lib>.h` and checks it against
//! the package's `src/capi.zig` (every header function exported with the same arity, every export
//! declared, the ABI number taken from `<lib>_abi_version`). Then it writes the thin raw layer:
//!
//!   Rust  packages/rust/libd2/src/sys/<lib>.rs     extern "C" + #[repr(C)], EXPECTED_ABI
//!   Go    packages/go/libd2/<dir>/zz_abi.go         purego-bound API struct, abiVersion
//!   .NET  packages/dotnet/LibD2/<Ns>/Native.g.cs    P/Invoke, ExpectedAbi
//!   npm   packages/npm/libd2/src/abi.ts             the wasm exports, struct layouts, EXPECTED_ABI
//!
//! and a smoke test per language that binds every function, checks the ABI number and every struct's
//! size against the C layout. The idiomatic wrappers in each language are written by hand on top.

const std = @import("std");
const cdecl = @import("cdecl.zig");
const capi_mod = @import("capi.zig");

const Library = struct {
    /// Library name, `d2drlg`: the shared library and the header's file name.
    lib: []const u8,
    /// Package directory under packages/.
    pkg: []const u8,
    /// Function name prefixes stripped for idiomatic names.
    prefixes: []const []const u8,
    go_dir: []const u8,
    dotnet_ns: []const u8,
    /// Linked into the combined wasm (and so in the npm package).
    wasm: bool = true,
};

pub const libraries = [_]Library{
    .{ .lib = "d2drlg", .pkg = "drlg", .prefixes = &.{"d2drlg_"}, .go_dir = "drlg", .dotnet_ns = "Drlg" },
    .{ .lib = "d2pf", .pkg = "pathfinding", .prefixes = &.{"d2pf_"}, .go_dir = "pathfinding", .dotnet_ns = "Pathfinding" },
    .{ .lib = "d2item", .pkg = "item", .prefixes = &.{"d2item_"}, .go_dir = "item", .dotnet_ns = "Item" },
    .{ .lib = "d2itemdraw", .pkg = "itemdraw", .prefixes = &.{"d2itemdraw_"}, .go_dir = "itemdraw", .dotnet_ns = "ItemDraw" },
    .{ .lib = "d2net", .pkg = "net", .prefixes = &.{"d2net_"}, .go_dir = "net", .dotnet_ns = "Net" },
    .{ .lib = "d2util", .pkg = "util", .prefixes = &.{ "d2util_", "d2_" }, .go_dir = "util", .dotnet_ns = "Util" },
};

const Lib = struct {
    def: Library,
    h: cdecl.Header,
    abi: i64,
    /// The header that declared it, for the generated-from line.
    header_path: []const u8,
};

const Out = struct {
    a: std.mem.Allocator,
    files: std.ArrayListUnmanaged(struct { path: []const u8, body: []const u8 }) = .empty,

    fn add(self: *Out, path: []const u8, body: []const u8) !void {
        try self.files.append(self.a, .{ .path = path, .body = body });
    }
};

/// A text buffer with formatted appends.
const W = struct {
    a: std.mem.Allocator,
    buf: std.ArrayListUnmanaged(u8) = .empty,

    fn p(self: *W, comptime fmt: []const u8, args: anytype) !void {
        try self.buf.print(self.a, fmt, args);
    }
    fn s(self: *W, text: []const u8) !void {
        try self.buf.appendSlice(self.a, text);
    }
};

pub fn main(init: std.process.Init.Minimal) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();

    var args = std.process.Args.Iterator.init(init.args);
    _ = args.next();
    const root = args.next() orelse fatal("usage: bindgen <repo root> [--check]", .{});
    const check = if (args.next()) |f| std.mem.eql(u8, f, "--check") else false;
    const dir = std.Io.Dir.cwd();

    var libs: std.ArrayListUnmanaged(Lib) = .empty;
    var bad = false;
    for (libraries) |def| {
        const hp = try std.fmt.allocPrint(a, "packages/{s}/include/{s}.h", .{ def.pkg, def.lib });
        const src = dir.readFileAlloc(io, try join(a, root, hp), a, .limited(1 << 20)) catch fatal("cannot read {s}", .{hp});
        const h = cdecl.parse(a, src) catch fatal("{s}: cannot parse", .{hp});
        const cp = try std.fmt.allocPrint(a, "packages/{s}/src/capi.zig", .{def.pkg});
        const csrc = dir.readFileAllocOptions(io, try join(a, root, cp), a, .limited(1 << 22), .of(u8), 0) catch fatal("cannot read {s}", .{cp});
        const c = try capi_mod.read(a, csrc);
        // the header against the exports
        for (h.funcs.items) |f| {
            const e = c.find(f.name) orelse {
                std.debug.print("{s}: {s} is declared but {s} does not export it\n", .{ hp, f.name, cp });
                bad = true;
                continue;
            };
            const returns = !(std.mem.eql(u8, f.ret.base, "void") and f.ret.ptr == 0);
            if (e.params != f.params.len or e.returns != returns) {
                std.debug.print("{s}: {s} has {d} parameters (returns: {}) but the export has {d} (returns: {})\n", .{ hp, f.name, f.params.len, returns, e.params, e.returns });
                bad = true;
            }
        }
        for (c.exports) |e| {
            var found = false;
            for (h.funcs.items) |f| found = found or std.mem.eql(u8, f.name, e.name);
            if (!found) {
                std.debug.print("{s}: exports {s}, which {s} does not declare\n", .{ cp, e.name, hp });
                bad = true;
            }
        }
        const abi = c.abi orelse fatal("{s}: no {s}_abi_version returning a number", .{ cp, def.lib });
        try libs.append(a, .{ .def = def, .h = h, .abi = abi, .header_path = hp });
    }
    if (bad) std.process.exit(1);

    var out = Out{ .a = a };
    try rust(a, &out, libs.items);
    for (libs.items) |*l| try goLib(a, &out, l);
    for (libs.items) |*l| try dotnetLib(a, &out, l);
    try dotnetTests(a, &out, libs.items);
    try ts(a, &out, libs.items);

    var stale: usize = 0;
    for (out.files.items) |f| {
        const path = try join(a, root, f.path);
        if (check) {
            const cur = dir.readFileAlloc(io, path, a, .limited(1 << 24)) catch "";
            if (!std.mem.eql(u8, cur, f.body)) {
                std.debug.print("stale: {s}\n", .{f.path});
                stale += 1;
            }
        } else {
            if (std.fs.path.dirname(path)) |d| dir.createDirPath(io, d) catch {};
            try dir.writeFile(io, .{ .sub_path = path, .data = f.body });
        }
    }
    if (check and stale != 0) {
        std.debug.print("{d} generated binding file(s) are out of date: run `zig build bindings`\n", .{stale});
        std.process.exit(1);
    }
    if (!check) std.debug.print("wrote {d} files for {d} libraries\n", .{ out.files.items.len, libs.items.len });
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("bindgen: " ++ fmt ++ "\n", args);
    std.process.exit(2);
}

fn join(a: std.mem.Allocator, root: []const u8, rel: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}/{s}", .{ root, rel });
}

// -------------------------------------------------------------------------------------------------
// names and kinds

/// `ctx_create` -> `CtxCreate`.
fn camel(a: std.mem.Allocator, snake: []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var up = true;
    for (snake) |c| {
        if (c == '_') {
            up = true;
            continue;
        }
        try out.append(a, if (up) std.ascii.toUpper(c) else c);
        up = false;
    }
    return out.items;
}

fn stripPrefix(l: *const Lib, name: []const u8) []const u8 {
    for (l.def.prefixes) |p| if (std.mem.startsWith(u8, name, p)) return name[p.len..];
    return name;
}

/// A pointer to an opaque handle (or `void *`): passed as an address, never dereferenced.
fn isHandle(h: *const cdecl.Header, t: cdecl.Type) bool {
    if (t.ptr != 1) return false;
    if (std.mem.eql(u8, t.base, "void")) return true;
    if (h.findStruct(t.base)) |s| return s.fields == null;
    return false;
}

fn isCString(t: cdecl.Type) bool {
    return t.ptr == 1 and t.is_const and std.mem.eql(u8, t.base, "char");
}

fn isVoid(t: cdecl.Type) bool {
    return t.ptr == 0 and std.mem.eql(u8, t.base, "void");
}

fn hasPointers(h: *const cdecl.Header, s: *const cdecl.Struct) bool {
    for (s.fields.?) |f| {
        if (f.ty.ptr > 0 or h.isFnPtr(f.ty.base)) return true;
        if (h.findStruct(f.ty.base)) |inner| if (inner.fields != null and hasPointers(h, inner)) return true;
    }
    return false;
}

fn docLines(w: *W, doc: []const u8, prefix: []const u8) !void {
    if (doc.len == 0) return;
    var it = std.mem.splitScalar(u8, doc, '\n');
    while (it.next()) |line| try w.p("{s}{s}\n", .{ prefix, line });
}

// -------------------------------------------------------------------------------------------------
// Rust

fn rustPrim(base: []const u8) ?[]const u8 {
    const t = [_][2][]const u8{
        .{ "int8_t", "i8" },   .{ "uint8_t", "u8" },   .{ "int16_t", "i16" }, .{ "uint16_t", "u16" },
        .{ "int32_t", "i32" }, .{ "uint32_t", "u32" }, .{ "int64_t", "i64" }, .{ "uint64_t", "u64" },
        .{ "char", "c_char" }, .{ "size_t", "usize" }, .{ "int", "i32" },
    };
    for (t) |e| if (std.mem.eql(u8, e[0], base)) return e[1];
    return null;
}

fn rustType(a: std.mem.Allocator, t: cdecl.Type) ![]const u8 {
    var inner: []const u8 = if (std.mem.eql(u8, t.base, "void")) "c_void" else rustPrim(t.base) orelse t.base;
    if (t.ptr == 0) {
        if (std.mem.eql(u8, t.base, "void")) return "()";
        if (t.array > 0) return std.fmt.allocPrint(a, "[{s}; {d}]", .{ inner, t.array });
        return inner;
    }
    var d: u8 = 0;
    while (d < t.ptr) : (d += 1) {
        const c = (d == 0 and t.is_const);
        inner = try std.fmt.allocPrint(a, "*{s} {s}", .{ if (c) "const" else "mut", inner });
    }
    return inner;
}

fn rustFnSig(a: std.mem.Allocator, w: *W, params: []const cdecl.Param, ret: cdecl.Type) !void {
    try w.s("(");
    for (params, 0..) |p, i| {
        if (i != 0) try w.s(", ");
        try w.p("{s}: {s}", .{ rustIdent(p.name), try rustType(a, p.ty) });
    }
    try w.s(")");
    if (!isVoid(ret)) try w.p(" -> {s}", .{try rustType(a, ret)});
}

fn rustIdent(name: []const u8) []const u8 {
    inline for (.{ "type", "fn", "ref", "mod", "move", "box", "in", "match", "loop", "use" }) |k| {
        if (std.mem.eql(u8, k, name)) return "r#" ++ k;
    }
    return name;
}

fn rust(a: std.mem.Allocator, out: *Out, libs: []Lib) !void {
    var mod = W{ .a = a };
    try mod.s("// Code generated by tools/bindgen from the C headers. DO NOT EDIT.\n\n");
    try mod.s("//! The raw C ABI of every libd2 library, one module per library, exactly as its header declares\n");
    try mod.s("//! it. The safe wrappers in this crate are built on these.\n\n#![allow(missing_docs)]\n\n");
    var tests = W{ .a = a };
    try tests.s("// Code generated by tools/bindgen from the C headers. DO NOT EDIT.\n\n");
    try tests.s("//! Every generated declaration links, every library reports the ABI the declarations were\n");
    try tests.s("//! generated for, and every struct has the C layout.\n\n");
    try tests.s("use libd2::sys;\n");
    for (libs) |*l| {
        try mod.p("pub mod {s};\n", .{l.def.lib});
        var w = W{ .a = a };
        try w.p("// Code generated by tools/bindgen from {s}. DO NOT EDIT.\n\n", .{l.header_path});
        try w.p("//! The raw `{s}` C ABI.\n\n", .{l.def.lib});
        try w.s("#![allow(non_camel_case_types, non_snake_case, non_upper_case_globals, dead_code, missing_docs, clippy::all)]\n\n");
        try w.s("#[allow(unused_imports)]\nuse core::ffi::{c_char, c_void};\n\n");
        try w.p("/// The ABI version these declarations were generated for; `{s}_abi_version` must report it.\n", .{l.def.lib});
        try w.p("pub const EXPECTED_ABI: u32 = {d};\n\n", .{l.abi});
        for (l.h.consts.items) |c| {
            try docLines(&w, c.doc, "/// ");
            const ty = if (c.value >= std.math.minInt(i32) and c.value <= std.math.maxInt(i32)) "i32" else "i64";
            try w.p("pub const {s}: {s} = {d};\n", .{ c.name, ty, c.value });
        }
        if (l.h.consts.items.len != 0) try w.s("\n");
        for (l.h.structs.items) |*st| {
            try docLines(&w, st.doc, "/// ");
            const fields = st.fields orelse {
                try w.p("#[repr(C)]\npub struct {s} {{\n    _private: [u8; 0],\n}}\n\n", .{st.name});
                continue;
            };
            try w.p("#[repr(C)]\n#[derive(Clone, Copy, Debug{s})]\npub struct {s} {{\n", .{ if (hasPointers(&l.h, st)) "" else ", PartialEq, Eq, Hash", st.name });
            for (fields) |f| {
                try docLines(&w, f.doc, "    /// ");
                try w.p("    pub {s}: {s},\n", .{ rustIdent(f.name), try rustType(a, f.ty) });
            }
            try w.s("}\n\n");
        }
        for (l.h.fnptrs.items) |f| {
            try docLines(&w, f.doc, "/// ");
            try w.p("pub type {s} = Option<unsafe extern \"C\" fn", .{f.name});
            try rustFnSig(a, &w, f.params, f.ret);
            try w.s(">;\n\n");
        }
        try w.s("extern \"C\" {\n");
        for (l.h.funcs.items) |f| {
            try docLines(&w, f.doc, "    /// ");
            try w.p("    pub fn {s}", .{f.name});
            try rustFnSig(a, &w, f.params, f.ret);
            try w.s(";\n");
        }
        try w.s("}\n");
        try out.add(try std.fmt.allocPrint(a, "packages/rust/libd2/src/sys/{s}.rs", .{l.def.lib}), w.buf.items);

        // smoke tests
        try tests.p("\n#[test]\nfn {s}_abi() {{\n    assert_eq!(unsafe {{ sys::{s}::{s}_abi_version() }} as u32, sys::{s}::EXPECTED_ABI);\n}}\n", .{ l.def.lib, l.def.lib, l.def.lib, l.def.lib });
        try tests.p("\n#[test]\nfn {s}_links_every_function() {{\n    let fns: [usize; {d}] = [\n", .{ l.def.lib, l.h.funcs.items.len });
        for (l.h.funcs.items) |f| try tests.p("        sys::{s}::{s} as *const () as usize,\n", .{ l.def.lib, f.name });
        try tests.s("    ];\n    assert!(fns.iter().all(|&f| f != 0));\n}\n");
        var any_struct = false;
        for (l.h.structs.items) |*st| any_struct = any_struct or st.fields != null;
        if (any_struct) {
            try tests.p("\n#[test]\nfn {s}_struct_layouts() {{\n    let wide = cfg!(target_pointer_width = \"64\");\n", .{l.def.lib});
            for (l.h.structs.items) |*st| {
                if (st.fields == null) continue;
                try tests.p("    assert_eq!(core::mem::size_of::<sys::{s}::{s}>(), if wide {{ {d} }} else {{ {d} }});\n", .{ l.def.lib, st.name, cdecl.structLayout(&l.h, st, .p64).size, cdecl.structLayout(&l.h, st, .p32).size });
            }
            try tests.s("}\n");
        }
    }
    try out.add("packages/rust/libd2/src/sys/mod.rs", mod.buf.items);
    try out.add("packages/rust/libd2/tests/generated_abi.rs", tests.buf.items);
}

// -------------------------------------------------------------------------------------------------
// Go (purego, no cgo: the module embeds the shared library per platform and needs no C toolchain)

fn goPrim(base: []const u8) ?[]const u8 {
    const t = [_][2][]const u8{
        .{ "int8_t", "int8" },   .{ "uint8_t", "uint8" },   .{ "int16_t", "int16" }, .{ "uint16_t", "uint16" },
        .{ "int32_t", "int32" }, .{ "uint32_t", "uint32" }, .{ "int64_t", "int64" }, .{ "uint64_t", "uint64" },
        .{ "char", "byte" },     .{ "size_t", "uintptr" },  .{ "int", "int32" },
    };
    for (t) |e| if (std.mem.eql(u8, e[0], base)) return e[1];
    return null;
}

const GoUse = struct { unsafe: bool = false };

fn goParam(h: *const cdecl.Header, t: cdecl.Type, use: *GoUse) []const u8 {
    if (h.isFnPtr(t.base) and t.ptr == 0) return "uintptr";
    if (t.ptr == 0) return goPrim(t.base) orelse t.base;
    if (isCString(t)) return "string";
    if (isHandle(h, t)) return "uintptr";
    use.unsafe = true;
    return "unsafe.Pointer";
}

fn goRet(h: *const cdecl.Header, t: cdecl.Type) []const u8 {
    if (t.ptr == 0) return goPrim(t.base) orelse t.base;
    _ = h;
    return "uintptr";
}

fn goField(a: std.mem.Allocator, h: *const cdecl.Header, t: cdecl.Type) ![]const u8 {
    const base: []const u8 = if (t.ptr > 0 or h.isFnPtr(t.base)) "uintptr" else goPrim(t.base) orelse t.base;
    if (t.array > 0 and t.ptr == 0) return std.fmt.allocPrint(a, "[{d}]{s}", .{ t.array, base });
    return base;
}

fn goLib(a: std.mem.Allocator, out: *Out, l: *const Lib) !void {
    var use = GoUse{};
    var body = W{ .a = a };
    // constants
    if (l.h.consts.items.len != 0) {
        try body.s("// The constants of the header.\nconst (\n");
        var rows: std.ArrayListUnmanaged(Row) = .empty;
        for (l.h.consts.items) |c| try rows.append(a, .{ .doc = c.doc, .name = c.name, .rest = try std.fmt.allocPrint(a, "= {d}", .{c.value}) });
        try goRows(&body, rows.items);
        try body.s(")\n\n");
    }
    for (l.h.structs.items) |*st| {
        const fields = st.fields orelse continue;
        try docLines(&body, st.doc, "// ");
        try body.p("type {s} struct {{\n", .{st.name});
        var rows: std.ArrayListUnmanaged(Row) = .empty;
        for (fields) |f| try rows.append(a, .{ .doc = f.doc, .name = try camel(a, f.name), .rest = try goField(a, &l.h, f.ty) });
        try goRows(&body, rows.items);
        try body.s("}\n\n");
    }
    try body.p("// API is every entry point of the {s} C ABI, bound with purego. Pointers to opaque handles cross\n", .{l.def.lib});
    try body.s("// as uintptr, buffers and out-parameters as unsafe.Pointer, `const char *` as a Go string.\n");
    try body.s("type API struct {\n");
    var rows: std.ArrayListUnmanaged(Row) = .empty;
    for (l.h.funcs.items) |f| {
        var sig = W{ .a = a };
        try sig.s("func(");
        for (f.params, 0..) |p, i| {
            if (i != 0) try sig.s(", ");
            try sig.p("{s} {s}", .{ goIdent(p.name), goParam(&l.h, p.ty, &use) });
        }
        try sig.s(")");
        if (!isVoid(f.ret)) try sig.p(" {s}", .{goRet(&l.h, f.ret)});
        try rows.append(a, .{ .doc = f.doc, .name = try camel(a, stripPrefix(l, f.name)), .rest = sig.buf.items });
    }
    try goRows(&body, rows.items);
    try body.s("}\n\n");
    try body.s("var (\n\tapiOnce   sync.Once\n\tapiLoaded *API\n\tapiErr    error\n)\n\n");
    try body.p("// Load opens the {s} library and binds every entry point, once per process, refusing a library\n// that reports another ABI than abiVersion.\n", .{l.def.lib});
    try body.p("func Load() (*API, error) {{\n\tapiOnce.Do(func() {{\n\t\tl, err := lib.Open(\"{s}\")\n\t\tif err != nil {{\n\t\t\tapiErr = err\n\t\t\treturn\n\t\t}}\n\t\ta := &API{{}}\n\t\tbinds := []struct {{\n\t\t\tfn  any\n\t\t\tsym string\n\t\t}}{{\n", .{l.def.lib});
    for (l.h.funcs.items) |f| try body.p("\t\t\t{{&a.{s}, \"{s}\"}},\n", .{ try camel(a, stripPrefix(l, f.name)), f.name });
    try body.s("\t\t}\n\t\tfor _, b := range binds {\n\t\t\tif err := lib.Bind(l, b.fn, b.sym); err != nil {\n\t\t\t\tapiErr = err\n\t\t\t\treturn\n\t\t\t}\n\t\t}\n");
    const abi_fn = try camel(a, stripPrefix(l, try std.fmt.allocPrint(a, "{s}_abi_version", .{l.def.lib})));
    try body.p("\t\tif err := lib.Verify(l, uint32(a.{s}()), abiVersion); err != nil {{\n\t\t\tapiErr = err\n\t\t\treturn\n\t\t}}\n\t\tapiLoaded = a\n\t}})\n\treturn apiLoaded, apiErr\n}}\n", .{abi_fn});

    var w = W{ .a = a };
    try w.p("// Code generated by tools/bindgen from {s}. DO NOT EDIT.\n\n", .{l.header_path});
    try w.p("package {s}\n\nimport (\n\t\"sync\"\n", .{l.def.go_dir});
    if (use.unsafe) try w.s("\t\"unsafe\"\n");
    try w.s("\n\t\"github.com/libd2/go/internal/lib\"\n)\n\n");
    try w.p("// abiVersion is the {s} C ABI this package was generated against.\nconst abiVersion = {d}\n\n", .{ l.def.lib, l.abi });
    try w.s(body.buf.items);
    try out.add(try std.fmt.allocPrint(a, "packages/go/libd2/{s}/zz_abi.go", .{l.def.go_dir}), w.buf.items);

    // smoke test
    var t = W{ .a = a };
    try t.p("// Code generated by tools/bindgen from {s}. DO NOT EDIT.\n\n", .{l.header_path});
    try t.p("package {s}\n\nimport (\n\t\"reflect\"\n\t\"testing\"\n\t\"unsafe\"\n)\n\n", .{l.def.go_dir});
    try t.s("// Every entry point binds and the library reports the generated ABI.\nfunc TestGeneratedAPI(t *testing.T) {\n\ta, err := Load()\n\tif err != nil {\n\t\tt.Fatal(err)\n\t}\n");
    try t.s("\tv := reflect.ValueOf(a).Elem()\n\tfor i := 0; i < v.NumField(); i++ {\n\t\tif v.Field(i).IsNil() {\n\t\t\tt.Errorf(\"%s is not bound\", v.Type().Field(i).Name)\n\t\t}\n\t}\n}\n\n");
    try t.s("// Every struct has the size C gives it.\nfunc TestGeneratedLayouts(t *testing.T) {\n\twide := unsafe.Sizeof(uintptr(0)) == 8\n\tsize := func(w, n uintptr) uintptr {\n\t\tif wide {\n\t\t\treturn w\n\t\t}\n\t\treturn n\n\t}\n\t_ = size\n");
    for (l.h.structs.items) |*st| {
        if (st.fields == null) continue;
        try t.p("\tif got, want := unsafe.Sizeof({s}{{}}), size({d}, {d}); got != want {{\n\t\tt.Errorf(\"sizeof({s}) = %d, want %d\", got, want)\n\t}}\n", .{ st.name, cdecl.structLayout(&l.h, st, .p64).size, cdecl.structLayout(&l.h, st, .p32).size, st.name });
    }
    try t.s("}\n");
    try out.add(try std.fmt.allocPrint(a, "packages/go/libd2/{s}/zz_abi_test.go", .{l.def.go_dir}), t.buf.items);
}

const Row = struct { doc: []const u8, name: []const u8, rest: []const u8 };

/// Rows of `name rest` the way gofmt lays them out: a comment line ends a run, and within a run the
/// names are padded to the longest.
fn goRows(w: *W, rows: []const Row) !void {
    var i: usize = 0;
    while (i < rows.len) {
        var j = i + 1;
        while (j < rows.len and rows[j].doc.len == 0) j += 1;
        var width: usize = 0;
        for (rows[i..j]) |r| width = @max(width, r.name.len);
        for (rows[i..j]) |r| {
            try docLines(w, r.doc, "\t// ");
            try w.p("\t{s}", .{r.name});
            var k = r.name.len;
            while (k < width + 1) : (k += 1) try w.s(" ");
            try w.p("{s}\n", .{r.rest});
        }
        i = j;
    }
}

fn goIdent(name: []const u8) []const u8 {
    const kw = [_][]const u8{ "type", "func", "range", "map", "chan", "len", "cap", "string", "default", "select" };
    for (kw) |k| if (std.mem.eql(u8, k, name)) return if (std.mem.eql(u8, k, "len")) "n" else if (std.mem.eql(u8, k, "cap")) "capacity" else "v";
    return name;
}

// -------------------------------------------------------------------------------------------------
// .NET

fn csPrim(base: []const u8) ?[]const u8 {
    const t = [_][2][]const u8{
        .{ "int8_t", "sbyte" }, .{ "uint8_t", "byte" },   .{ "int16_t", "short" }, .{ "uint16_t", "ushort" },
        .{ "int32_t", "int" },  .{ "uint32_t", "uint" },  .{ "int64_t", "long" },  .{ "uint64_t", "ulong" },
        .{ "char", "byte" },    .{ "size_t", "UIntPtr" }, .{ "int", "int" },
    };
    for (t) |e| if (std.mem.eql(u8, e[0], base)) return e[1];
    return null;
}

fn csParam(a: std.mem.Allocator, h: *const cdecl.Header, t: cdecl.Type) ![]const u8 {
    if (h.isFnPtr(t.base) and t.ptr == 0) return "IntPtr";
    if (t.ptr == 0) return csPrim(t.base) orelse t.base;
    if (isCString(t)) return "[MarshalAs(UnmanagedType.LPStr)] string";
    if (isHandle(h, t)) return "IntPtr";
    const inner: []const u8 = if (std.mem.eql(u8, t.base, "void")) "void" else csPrim(t.base) orelse t.base;
    var stars: [4]u8 = undefined;
    @memset(stars[0..t.ptr], '*');
    return std.fmt.allocPrint(a, "{s}{s}", .{ inner, stars[0..t.ptr] });
}

fn csRet(h: *const cdecl.Header, t: cdecl.Type) []const u8 {
    if (isVoid(t)) return "void";
    if (t.ptr == 0) return csPrim(t.base) orelse t.base;
    _ = h;
    return "IntPtr";
}

fn csIdent(name: []const u8) []const u8 {
    inline for (.{ "out", "in", "ref", "params", "string", "object", "base", "event", "fixed", "checked", "lock" }) |k| {
        if (std.mem.eql(u8, k, name)) return "@" ++ k;
    }
    return name;
}

fn dotnetLib(a: std.mem.Allocator, out: *Out, l: *const Lib) !void {
    var w = W{ .a = a };
    try w.p("// <auto-generated>\n// Generated by tools/bindgen from {s}. Do not edit.\n// </auto-generated>\n\n", .{l.header_path});
    try w.s("using System;\nusing System.Runtime.InteropServices;\n\n// The C header documents each declaration; the safe wrappers carry the documentation.\n#pragma warning disable CS1591\n\n");
    try w.p("namespace LibD2.{s};\n\n", .{l.def.dotnet_ns});
    try w.p("/// <summary>The raw <c>{s}</c> C ABI, exactly as its header declares it.</summary>\n", .{l.def.lib});
    try w.s("public static unsafe partial class Native\n{\n");
    try w.p("    private const string Lib = \"{s}\";\n\n", .{l.def.lib});
    try w.p("    /// <summary>The ABI version these declarations were generated for.</summary>\n    public const uint ExpectedAbi = {d};\n\n", .{l.abi});
    for (l.h.consts.items) |c| {
        const ty = if (c.value >= std.math.minInt(i32) and c.value <= std.math.maxInt(i32)) "int" else "long";
        try w.p("    public const {s} {s} = {d};\n", .{ ty, c.name, c.value });
    }
    if (l.h.consts.items.len != 0) try w.s("\n");
    for (l.h.funcs.items) |f| {
        if (f.doc.len != 0) {
            try w.s("    /// <summary>\n");
            var it = std.mem.splitScalar(u8, f.doc, '\n');
            while (it.next()) |line| try w.p("    /// {s}\n", .{try xmlEscape(a, line)});
            try w.s("    /// </summary>\n");
        }
        try w.s("    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]\n");
        try w.p("    public static extern {s} {s}(", .{ csRet(&l.h, f.ret), f.name });
        for (f.params, 0..) |p, i| {
            if (i != 0) try w.s(", ");
            try w.p("{s} {s}", .{ try csParam(a, &l.h, p.ty), csIdent(p.name) });
        }
        try w.s(");\n\n");
    }
    try w.s("}\n");
    for (l.h.structs.items) |*st| {
        const fields = st.fields orelse continue;
        try w.p("\n/// <summary>The C struct <c>{s}</c>.</summary>\n[StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]\npublic unsafe struct {s}\n{{\n", .{ st.name, st.name });
        for (fields) |f| {
            const ptrish = f.ty.ptr > 0 or l.h.isFnPtr(f.ty.base);
            const base: []const u8 = if (ptrish) "IntPtr" else csPrim(f.ty.base) orelse f.ty.base;
            if (f.ty.array > 0 and !ptrish) {
                try w.p("    public fixed {s} {s}[{d}];\n", .{ base, csIdent(f.name), f.ty.array });
            } else try w.p("    public {s} {s};\n", .{ base, csIdent(f.name) });
        }
        try w.s("}\n");
    }
    try out.add(try std.fmt.allocPrint(a, "packages/dotnet/LibD2/{s}/Native.g.cs", .{l.def.dotnet_ns}), w.buf.items);
}

fn xmlEscape(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (s) |c| switch (c) {
        '<' => try out.appendSlice(a, "&lt;"),
        '>' => try out.appendSlice(a, "&gt;"),
        '&' => try out.appendSlice(a, "&amp;"),
        else => try out.append(a, c),
    };
    return out.items;
}

fn dotnetTests(a: std.mem.Allocator, out: *Out, libs: []Lib) !void {
    var w = W{ .a = a };
    try w.s("// <auto-generated>\n// Generated by tools/bindgen from the C headers. Do not edit.\n// </auto-generated>\n\n");
    try w.s("using System;\nusing System.Runtime.InteropServices;\nusing Xunit;\n\nnamespace LibD2.Tests;\n\n");
    try w.s("/// <summary>Every library reports the generated ABI, exports every declared function, and every\n/// struct has the C layout.</summary>\npublic class GeneratedAbi\n{\n");
    for (libs) |*l| {
        try w.p("    [Fact]\n    public void {s}_abi() => Assert.Equal(LibD2.{s}.Native.ExpectedAbi, (uint)LibD2.{s}.Native.{s}_abi_version());\n\n", .{ l.def.lib, l.def.dotnet_ns, l.def.dotnet_ns, l.def.lib });
        try w.p("    [Fact]\n    public void {s}_exports()\n    {{\n        var lib = NativeLibrary.Load(\"{s}\", typeof(LibD2.{s}.Native).Assembly, null);\n", .{ l.def.lib, l.def.lib, l.def.dotnet_ns });
        for (l.h.funcs.items) |f| try w.p("        Assert.True(NativeLibrary.TryGetExport(lib, \"{s}\", out _), \"{s}\");\n", .{ f.name, f.name });
        try w.s("    }\n\n");
        var any = false;
        for (l.h.structs.items) |*st| any = any or st.fields != null;
        if (!any) continue;
        try w.p("    [Fact]\n    public void {s}_layouts()\n    {{\n        var wide = IntPtr.Size == 8;\n", .{l.def.lib});
        for (l.h.structs.items) |*st| {
            if (st.fields == null) continue;
            try w.p("        Assert.Equal(wide ? {d} : {d}, Marshal.SizeOf<LibD2.{s}.{s}>());\n", .{ cdecl.structLayout(&l.h, st, .p64).size, cdecl.structLayout(&l.h, st, .p32).size, l.def.dotnet_ns, st.name });
        }
        try w.s("    }\n\n");
    }
    try w.s("}\n");
    try out.add("packages/dotnet/LibD2.Tests/GeneratedAbi.g.cs", w.buf.items);
}

// -------------------------------------------------------------------------------------------------
// npm: the combined wasm (wasm32, 4-byte pointers)

fn tsType(t: cdecl.Type) []const u8 {
    if (isVoid(t)) return "void";
    if (t.ptr == 0 and (std.mem.eql(u8, t.base, "int64_t") or std.mem.eql(u8, t.base, "uint64_t"))) return "bigint";
    return "number";
}

fn tsKind(h: *const cdecl.Header, t: cdecl.Type) []const u8 {
    if (t.ptr > 0 or h.isFnPtr(t.base) or std.mem.eql(u8, t.base, "size_t")) return "ptr";
    const m = [_][2][]const u8{
        .{ "int8_t", "i8" },   .{ "uint8_t", "u8" },   .{ "char", "u8" },     .{ "int16_t", "i16" }, .{ "uint16_t", "u16" },
        .{ "int32_t", "i32" }, .{ "uint32_t", "u32" }, .{ "int64_t", "i64" }, .{ "uint64_t", "u64" }, .{ "int", "i32" },
    };
    for (m) |e| if (std.mem.eql(u8, e[0], t.base)) return e[1];
    return t.base;
}

fn ts(a: std.mem.Allocator, out: *Out, libs: []Lib) !void {
    var w = W{ .a = a };
    try w.s("// Code generated by tools/bindgen from the C headers. DO NOT EDIT.\n//\n");
    try w.s("// The raw C ABI of the combined wasm: every export, every constant, every struct's wasm32 layout.\n\n");
    try w.s("/** The ABI version of each library the declarations were generated for. */\nexport const EXPECTED_ABI = {\n");
    for (libs) |*l| if (l.def.wasm) try w.p("  {s}: {d},\n", .{ l.def.lib, l.abi });
    try w.s("} as const;\n\n");
    for (libs) |*l| {
        if (!l.def.wasm) continue;
        for (l.h.consts.items) |c| try w.p("export const {s} = {d};\n", .{ c.name, c.value });
    }
    try w.s("\n/** A field of a struct in wasm memory: byte offset and type (`ptr` is a 4-byte address). */\n");
    try w.s("export interface Field {\n  readonly offset: number;\n  readonly type: string;\n  readonly count?: number;\n}\n\n");
    try w.s("/** The wasm32 layout of every struct the ABI reads or writes. */\nexport const LAYOUT = {\n");
    for (libs) |*l| {
        if (!l.def.wasm) continue;
        for (l.h.structs.items) |*st| {
            const fields = st.fields orelse continue;
            const offs = try cdecl.fieldOffsets(a, &l.h, st, .p32);
            try w.p("  {s}: {{\n    size: {d},\n    fields: {{\n", .{ st.name, cdecl.structLayout(&l.h, st, .p32).size });
            for (fields, offs) |f, o| {
                if (f.ty.array > 0) {
                    try w.p("      {s}: {{ offset: {d}, type: '{s}', count: {d} }},\n", .{ f.name, o, tsKind(&l.h, f.ty), f.ty.array });
                } else try w.p("      {s}: {{ offset: {d}, type: '{s}' }},\n", .{ f.name, o, tsKind(&l.h, f.ty) });
            }
            try w.s("    },\n  },\n");
        }
    }
    try w.s("} as const;\n\n");
    try w.s("/** Every function the combined wasm exports, as the headers declare them; pointers are numbers. */\nexport interface Exports {\n  memory: WebAssembly.Memory;\n");
    for (libs) |*l| {
        if (!l.def.wasm) continue;
        try w.p("\n  // {s}\n", .{l.def.lib});
        for (l.h.funcs.items) |f| {
            if (f.doc.len != 0) {
                try w.s("  /**\n");
                var it = std.mem.splitScalar(u8, f.doc, '\n');
                while (it.next()) |line| try w.p("   * {s}\n", .{try commentSafe(a, line)});
                try w.s("   */\n");
            }
            try w.p("  {s}(", .{f.name});
            for (f.params, 0..) |p, i| {
                if (i != 0) try w.s(", ");
                try w.p("{s}: {s}", .{ p.name, tsType(p.ty) });
            }
            try w.p("): {s};\n", .{tsType(f.ret)});
        }
    }
    try w.s("}\n\n/** The name of every function in `Exports`, for a module check. */\nexport const EXPORT_NAMES = [\n");
    for (libs) |*l| {
        if (!l.def.wasm) continue;
        for (l.h.funcs.items) |f| try w.p("  '{s}',\n", .{f.name});
    }
    try w.s("] as const;\n");
    try out.add("packages/npm/libd2/src/abi.ts", w.buf.items);

    var t = W{ .a = a };
    try t.s("// Code generated by tools/bindgen from the C headers. DO NOT EDIT.\n\n");
    try t.s("import { test } from 'node:test';\nimport assert from 'node:assert/strict';\n\n");
    try t.s("import { EXPECTED_ABI, EXPORT_NAMES } from '../src/abi.ts';\nimport { load } from '../src/wasm.ts';\n\n");
    try t.s("test('the wasm exports every declared function and reports the generated ABIs', async () => {\n");
    try t.s("  const e = (await load()) as unknown as Record<string, unknown>;\n");
    try t.s("  for (const name of EXPORT_NAMES) assert.equal(typeof e[name], 'function', name);\n");
    try t.s("  for (const [lib, abi] of Object.entries(EXPECTED_ABI)) {\n");
    try t.s("    assert.equal(Number((e[`${lib}_abi_version`] as () => number)()), abi, lib);\n  }\n});\n");
    try out.add("packages/npm/libd2/test/abi.generated.test.ts", t.buf.items);
}

fn commentSafe(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    return std.mem.replaceOwned(u8, a, s, "*/", "* /");
}

test {
    _ = cdecl;
    _ = capi_mod;
}
