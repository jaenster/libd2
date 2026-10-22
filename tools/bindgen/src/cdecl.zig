//! The C subset libd2's headers are written in, parsed into declarations: opaque and plain struct
//! typedefs, function-pointer typedefs, anonymous enums and `#define` integer constants, and function
//! prototypes. Comments are dropped except the block right before a declaration, kept as its doc.

const std = @import("std");

pub const Type = struct {
    /// `int32_t`, `char`, `void`, a struct or function-pointer typedef name.
    base: []const u8,
    /// `const` on the pointee (or on the value when not a pointer).
    is_const: bool = false,
    /// Pointer depth: `T *` is 1, `T **` 2. An array parameter counts as a pointer.
    ptr: u8 = 0,
    /// Fixed array length of a struct field, 0 for none.
    array: u32 = 0,
};

pub const Field = struct { name: []const u8, ty: Type, doc: []const u8 = "" };
pub const Param = struct { name: []const u8, ty: Type };

pub const Struct = struct { name: []const u8, fields: ?[]Field, doc: []const u8 };
pub const FnPtr = struct { name: []const u8, ret: Type, params: []Param, doc: []const u8 };
pub const Func = struct { name: []const u8, ret: Type, params: []Param, doc: []const u8 };
pub const Const = struct { name: []const u8, value: i64, doc: []const u8 };

pub const Header = struct {
    structs: std.ArrayListUnmanaged(Struct) = .empty,
    fnptrs: std.ArrayListUnmanaged(FnPtr) = .empty,
    funcs: std.ArrayListUnmanaged(Func) = .empty,
    consts: std.ArrayListUnmanaged(Const) = .empty,

    pub fn findStruct(self: *const Header, name: []const u8) ?*const Struct {
        for (self.structs.items) |*s| if (std.mem.eql(u8, s.name, name)) return s;
        return null;
    }
    pub fn isFnPtr(self: *const Header, name: []const u8) bool {
        for (self.fnptrs.items) |f| if (std.mem.eql(u8, f.name, name)) return true;
        return false;
    }
};

pub const Error = error{ Syntax, OutOfMemory };

const Tok = struct {
    text: []const u8,
    /// The comment block just before this token, when it starts a declaration.
    doc: []const u8 = "",
    /// A comment that follows this token on its own line (`int32_t x; /* doc */`).
    trail: []const u8 = "",
};

/// Tokens of the header with comments and preprocessor lines removed, keeping each comment block as
/// the doc of the token after it. `#define NAME <integer>` lines become constants directly.
fn tokenize(a: std.mem.Allocator, src: []const u8, h: *Header, errpos: *usize) Error![]Tok {
    var toks: std.ArrayListUnmanaged(Tok) = .empty;
    var doc: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    var line_start = true;
    var same_line = false;
    while (i < src.len) {
        const c = src[i];
        if (c == '\n') {
            line_start = true;
            same_line = false;
            i += 1;
            continue;
        }
        if (c == ' ' or c == '\t' or c == '\r') {
            i += 1;
            continue;
        }
        if (line_start and c == '#') {
            const end = std.mem.indexOfScalarPos(u8, src, i, '\n') orelse src.len;
            const line = src[i..end];
            try defineConst(a, line, h, doc.items);
            doc.clearRetainingCapacity();
            i = end;
            continue;
        }
        line_start = false;
        if (c == '/' and i + 1 < src.len and src[i + 1] == '*') {
            const end = std.mem.indexOfPos(u8, src, i + 2, "*/") orelse return error.Syntax;
            try comment(a, &doc, toks.items, same_line, src[i + 2 .. end]);
            i = end + 2;
            continue;
        }
        if (c == '/' and i + 1 < src.len and src[i + 1] == '/') {
            const end = std.mem.indexOfScalarPos(u8, src, i, '\n') orelse src.len;
            try comment(a, &doc, toks.items, same_line, src[i + 2 .. end]);
            i = end;
            continue;
        }
        var j = i + 1;
        if (std.ascii.isAlphanumeric(c) or c == '_') {
            while (j < src.len and (std.ascii.isAlphanumeric(src[j]) or src[j] == '_')) j += 1;
        } else if (c == '"') {
            while (j < src.len and src[j] != '"') j += 1;
            j += 1;
        } else if (c == '<' and j < src.len and src[j] == '<') {
            j += 1;
        }
        try toks.append(a, .{ .text = src[i..j], .doc = try a.dupe(u8, doc.items) });
        same_line = true;
        doc.clearRetainingCapacity();
        errpos.* = i;
        i = j;
    }
    return toks.items;
}

/// A comment on the line of the token before it trails that token; any other leads the next one.
fn comment(a: std.mem.Allocator, doc: *std.ArrayListUnmanaged(u8), toks: []Tok, same_line: bool, raw: []const u8) !void {
    if (same_line and toks.len != 0) {
        var t: std.ArrayListUnmanaged(u8) = .empty;
        try t.appendSlice(a, toks[toks.len - 1].trail);
        try appendDoc(a, &t, raw);
        toks[toks.len - 1].trail = t.items;
        return;
    }
    try appendDoc(a, doc, raw);
}

fn appendDoc(a: std.mem.Allocator, doc: *std.ArrayListUnmanaged(u8), raw: []const u8) !void {
    var it = std.mem.splitScalar(u8, raw, '\n');
    while (it.next()) |line| {
        var l = std.mem.trim(u8, line, " \t\r");
        while (l.len != 0 and l[0] == '*') l = std.mem.trimStart(u8, l[1..], " ");
        if (l.len == 0) continue;
        if (doc.items.len != 0) try doc.append(a, '\n');
        try doc.appendSlice(a, l);
    }
}

fn defineConst(a: std.mem.Allocator, line: []const u8, h: *Header, doc: []const u8) !void {
    var it = std.mem.tokenizeAny(u8, line, " \t\r");
    const d = it.next() orelse return;
    if (!std.mem.eql(u8, d, "#define")) return;
    const name = it.next() orelse return;
    const val = it.next() orelse return;
    if (it.next() != null) return;
    const v = std.fmt.parseInt(i64, val, 0) catch return;
    try h.consts.append(a, .{ .name = name, .value = v, .doc = try a.dupe(u8, doc) });
}

const Parser = struct {
    a: std.mem.Allocator,
    toks: []Tok,
    i: usize = 0,
    h: *Header,

    fn peek(p: *Parser) ?[]const u8 {
        return if (p.i < p.toks.len) p.toks[p.i].text else null;
    }
    fn next(p: *Parser) Error![]const u8 {
        if (p.i >= p.toks.len) return error.Syntax;
        p.i += 1;
        return p.toks[p.i - 1].text;
    }
    fn eat(p: *Parser, t: []const u8) bool {
        if (p.peek()) |x| if (std.mem.eql(u8, x, t)) {
            p.i += 1;
            return true;
        };
        return false;
    }
    fn expect(p: *Parser, t: []const u8) Error!void {
        if (!p.eat(t)) return error.Syntax;
    }

    /// `[const] base [const] *...` (no name).
    fn typeSpec(p: *Parser) Error!Type {
        var t = Type{ .base = "" };
        if (p.eat("const")) t.is_const = true;
        if (p.eat("struct")) {}
        t.base = try p.next();
        if (std.mem.eql(u8, t.base, "unsigned") or std.mem.eql(u8, t.base, "signed")) t.base = try p.next();
        if (p.eat("const")) t.is_const = true;
        while (p.eat("*")) {
            t.ptr += 1;
            _ = p.eat("const");
        }
        return t;
    }

    fn params(p: *Parser) Error![]Param {
        var out: std.ArrayListUnmanaged(Param) = .empty;
        try p.expect("(");
        if (p.eat(")")) return out.items;
        if (p.peek()) |x| if (std.mem.eql(u8, x, "void") and p.i + 1 < p.toks.len and std.mem.eql(u8, p.toks[p.i + 1].text, ")")) {
            p.i += 2;
            return out.items;
        };
        while (true) {
            var t = try p.typeSpec();
            const name = try p.next();
            if (p.eat("[")) {
                while (!p.eat("]")) _ = try p.next();
                t.ptr += 1;
            }
            try out.append(p.a, .{ .name = name, .ty = t });
            if (p.eat(")")) break;
            try p.expect(",");
        }
        return out.items;
    }

    fn skipToSemi(p: *Parser) void {
        while (p.i < p.toks.len and !std.mem.eql(u8, p.toks[p.i].text, ";")) p.i += 1;
        p.i += 1;
    }

    fn decl(p: *Parser) Error!void {
        const doc = p.toks[p.i].doc;
        const first = p.peek().?;
        if (std.mem.eql(u8, first, "extern")) {
            // extern "C" {
            p.i += 1;
            _ = p.eat("\"C\"");
            _ = p.eat("{");
            return;
        }
        if (std.mem.eql(u8, first, "}")) {
            p.i += 1;
            return;
        }
        if (std.mem.eql(u8, first, "typedef")) {
            p.i += 1;
            if (p.eat("struct")) {
                const tag = try p.next();
                if (p.eat("{")) {
                    var fields: std.ArrayListUnmanaged(Field) = .empty;
                    while (!p.eat("}")) {
                        const fdoc = p.toks[p.i].doc;
                        const base = try p.typeSpec();
                        while (true) {
                            var t = base;
                            while (p.eat("*")) t.ptr += 1;
                            const name = try p.next();
                            if (p.eat("[")) {
                                t.array = std.fmt.parseInt(u32, try p.next(), 0) catch return error.Syntax;
                                try p.expect("]");
                            }
                            const done = p.eat(";");
                            if (!done) try p.expect(",");
                            const trail = p.toks[p.i - 1].trail;
                            try fields.append(p.a, .{ .name = name, .ty = t, .doc = if (trail.len != 0) trail else fdoc });
                            if (done) break;
                        }
                    }
                    const name = try p.next();
                    try p.expect(";");
                    try p.h.structs.append(p.a, .{ .name = name, .fields = fields.items, .doc = doc });
                    _ = tag;
                    return;
                }
                const name = try p.next();
                try p.expect(";");
                if (p.h.findStruct(name) == null) try p.h.structs.append(p.a, .{ .name = name, .fields = null, .doc = doc });
                return;
            }
            // typedef RET (*NAME)(params);
            const ret = try p.typeSpec();
            try p.expect("(");
            try p.expect("*");
            const name = try p.next();
            try p.expect(")");
            const ps = try p.params();
            try p.expect(";");
            try p.h.fnptrs.append(p.a, .{ .name = name, .ret = ret, .params = ps, .doc = doc });
            return;
        }
        if (std.mem.eql(u8, first, "enum")) {
            p.i += 1;
            try p.expect("{");
            var last: i64 = -1;
            while (!p.eat("}")) {
                const cdoc = p.toks[p.i].doc;
                const name = try p.next();
                var v = last + 1;
                if (p.eat("=")) v = try p.constExpr();
                last = v;
                const comma = p.eat(",");
                const trail = if (comma) p.toks[p.i - 1].trail else p.toks[p.i - 1].trail;
                try p.h.consts.append(p.a, .{ .name = name, .value = v, .doc = if (trail.len != 0) trail else cdoc });
            }
            try p.expect(";");
            return;
        }
        // a function prototype, possibly behind a deprecation macro
        if (p.i + 1 < p.toks.len and std.mem.endsWith(u8, first, "_DEPRECATED") and std.mem.eql(u8, p.toks[p.i + 1].text, "(")) {
            p.i += 2;
            while (!p.eat(")")) p.i += 1;
        }
        const ret = try p.typeSpec();
        const name = try p.next();
        const ps = try p.params();
        try p.expect(";");
        try p.h.funcs.append(p.a, .{ .name = name, .ret = ret, .params = ps, .doc = if (doc.len != 0) doc else p.toks[p.i - 1].doc });
    }

    fn constExpr(p: *Parser) Error!i64 {
        var neg = false;
        if (p.eat("-")) neg = true;
        var v = std.fmt.parseInt(i64, try p.next(), 0) catch return error.Syntax;
        if (neg) v = -v;
        if (p.eat("<<")) {
            const s = std.fmt.parseInt(u6, try p.next(), 0) catch return error.Syntax;
            v <<= s;
        }
        return v;
    }
};

pub fn parse(a: std.mem.Allocator, src: []const u8) Error!Header {
    var h = Header{};
    var pos: usize = 0;
    const toks = try tokenize(a, src, &h, &pos);
    var p = Parser{ .a = a, .toks = toks, .h = &h };
    while (p.i < p.toks.len) try p.decl();
    return h;
}

// -------------------------------------------------------------------------------------------------
// C layout

pub const Abi = enum { p64, p32 };

pub fn primSize(base: []const u8) ?u32 {
    const t = [_]struct { n: []const u8, s: u32 }{
        .{ .n = "int8_t", .s = 1 },   .{ .n = "uint8_t", .s = 1 },  .{ .n = "char", .s = 1 },
        .{ .n = "int16_t", .s = 2 },  .{ .n = "uint16_t", .s = 2 }, .{ .n = "int32_t", .s = 4 },
        .{ .n = "uint32_t", .s = 4 }, .{ .n = "int64_t", .s = 8 },  .{ .n = "uint64_t", .s = 8 },
        .{ .n = "int", .s = 4 },
    };
    for (t) |e| if (std.mem.eql(u8, e.n, base)) return e.s;
    return null;
}

pub const Layout = struct { size: u32, alignment: u32 };

/// Size and alignment of a value of type `t` under `abi`.
pub fn layoutOf(h: *const Header, t: Type, abi: Abi) Layout {
    const ptr: u32 = if (abi == .p64) 8 else 4;
    const elem: Layout = blk: {
        if (t.ptr > 0 or h.isFnPtr(t.base) or std.mem.eql(u8, t.base, "size_t")) break :blk .{ .size = ptr, .alignment = ptr };
        if (primSize(t.base)) |s| break :blk .{ .size = s, .alignment = if (abi == .p32 and s == 8) 4 else s };
        if (h.findStruct(t.base)) |s| break :blk structLayout(h, s, abi);
        break :blk .{ .size = 0, .alignment = 1 };
    };
    if (t.array > 0 and t.ptr == 0) return .{ .size = elem.size * t.array, .alignment = elem.alignment };
    return elem;
}

pub fn fieldOffsets(a: std.mem.Allocator, h: *const Header, s: *const Struct, abi: Abi) ![]u32 {
    const fields = s.fields orelse return &.{};
    const out = try a.alloc(u32, fields.len);
    var off: u32 = 0;
    for (fields, 0..) |f, i| {
        const l = layoutOf(h, f.ty, abi);
        off = std.mem.alignForward(u32, off, l.alignment);
        out[i] = off;
        off += l.size;
    }
    return out;
}

pub fn structLayout(h: *const Header, s: *const Struct, abi: Abi) Layout {
    const fields = s.fields orelse return .{ .size = 0, .alignment = 1 };
    var off: u32 = 0;
    var al: u32 = 1;
    for (fields) |f| {
        const l = layoutOf(h, f.ty, abi);
        off = std.mem.alignForward(u32, off, l.alignment);
        off += l.size;
        al = @max(al, l.alignment);
    }
    return .{ .size = std.mem.alignForward(u32, off, al), .alignment = al };
}

test "a header's declarations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\#define X_ABI_VERSION 3
        \\typedef struct XCtx XCtx;
        \\/* A rect. */
        \\typedef struct XRect { int32_t x, y; uint8_t name[16]; const char *s; } XRect;
        \\enum { X_A = 0, X_B = 1 << 2, X_C = -1 };
        \\typedef int32_t (*x_fn)(void *user, const XRect *r);
        \\XCtx *x_create(void);
        \\int32_t x_box(const uint8_t *src, int32_t box_out[4]);
    ;
    const h = try parse(arena.allocator(), src);
    try std.testing.expectEqual(@as(usize, 2), h.structs.items.len);
    try std.testing.expectEqual(@as(usize, 4), h.consts.items.len);
    try std.testing.expectEqual(@as(i64, 4), h.consts.items[2].value);
    try std.testing.expectEqual(@as(usize, 2), h.funcs.items.len);
    try std.testing.expectEqual(@as(u8, 1), h.funcs.items[1].params[1].ty.ptr);
    const r = h.findStruct("XRect").?;
    try std.testing.expectEqual(@as(u32, 32), structLayout(&h, r, .p64).size);
    try std.testing.expectEqual(@as(u32, 28), structLayout(&h, r, .p32).size);
    try std.testing.expectEqualStrings("A rect.", r.doc);
}
