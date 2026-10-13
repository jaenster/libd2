//! What a package's `capi.zig` really exports, read with the Zig parser: every `export fn` with its
//! parameter count and whether it returns anything, and the number its `*_abi_version` returns. The
//! header is a claim; this is what it is checked against.

const std = @import("std");
const Ast = std.zig.Ast;

pub const Export = struct { name: []const u8, params: usize, returns: bool };

pub const Capi = struct {
    exports: []Export,
    abi: ?i64,

    pub fn find(self: *const Capi, name: []const u8) ?Export {
        for (self.exports) |e| if (std.mem.eql(u8, e.name, name)) return e;
        return null;
    }
};

pub fn read(a: std.mem.Allocator, source: [:0]const u8) !Capi {
    var tree = try Ast.parse(a, source, .zig);
    var out: std.ArrayListUnmanaged(Export) = .empty;
    var abi: ?i64 = null;
    for (tree.rootDecls()) |node| {
        var buf: [1]Ast.Node.Index = undefined;
        const proto = tree.fullFnProto(&buf, node) orelse continue;
        const ext = proto.extern_export_inline_token orelse continue;
        if (tree.tokenTag(ext) != .keyword_export) continue;
        const name = tree.tokenSlice(proto.name_token orelse continue);
        const returns = if (proto.ast.return_type.unwrap()) |rt| !std.mem.eql(u8, tree.getNodeSource(rt), "void") else false;
        try out.append(a, .{ .name = name, .params = proto.ast.params.len, .returns = returns });
        if (std.mem.endsWith(u8, name, "_abi_version") and tree.nodeTag(node) == .fn_decl) {
            abi = returnedNumber(&tree, node);
        }
    }
    return .{ .exports = out.items, .abi = abi };
}

/// The number a function body returns: a literal, or a top-level constant holding one.
fn returnedNumber(tree: *const Ast, fn_decl: Ast.Node.Index) ?i64 {
    const body = tree.nodeData(fn_decl).node_and_node[1];
    var t = tree.firstToken(body);
    const last = tree.lastToken(body);
    while (t < last) : (t += 1) {
        if (tree.tokenTag(t) != .keyword_return) continue;
        const v = t + 1;
        switch (tree.tokenTag(v)) {
            .number_literal => return std.fmt.parseInt(i64, tree.tokenSlice(v), 0) catch null,
            .identifier => return constValue(tree, tree.tokenSlice(v)),
            else => return null,
        }
    }
    return null;
}

fn constValue(tree: *const Ast, name: []const u8) ?i64 {
    for (tree.rootDecls()) |node| {
        const vd = tree.fullVarDecl(node) orelse continue;
        if (!std.mem.eql(u8, tree.tokenSlice(vd.ast.mut_token + 1), name)) continue;
        const init = vd.ast.init_node.unwrap() orelse return null;
        if (tree.nodeTag(init) != .number_literal) return null;
        return std.fmt.parseInt(i64, tree.tokenSlice(tree.nodeMainToken(init)), 0) catch null;
    }
    return null;
}

test "exports and the ABI number" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const c = try read(arena.allocator(),
        \\const ABI: u32 = 4;
        \\export fn x_abi_version() u32 { return ABI; }
        \\pub export fn x_free(p: ?*u8, n: usize) void { _ = p; _ = n; }
        \\fn helper() void {}
    );
    try std.testing.expectEqual(@as(usize, 2), c.exports.len);
    try std.testing.expectEqual(@as(?i64, 4), c.abi);
    try std.testing.expectEqual(@as(usize, 2), c.find("x_free").?.params);
    try std.testing.expect(!c.find("x_free").?.returns);
}
