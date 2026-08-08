#!/usr/bin/env python3
"""Generate d2-net's client->server packet module from the 1.14d packet structs.

Source of truth: the `D2GSPacketClt0xNN_*` structs recovered in Ghidra (session 62fbfe69) and
carried in the reconstruction headers, plus the `SCMD_0xNN_*` handler each one is passed to.
Every field keeps its recovered offset, so the emitted encode/decode is byte-exact by construction
rather than by transcription.
"""
import json, re, sys, os, glob

RECON = os.environ.get("D2_RECON", os.path.expanduser("~/code/CPP/diablo-2"))


def parse_structs(root):
    """Every `struct D2GSPacket*` in the reconstruction, with each field's recovered offset."""
    structs = {}
    pat = re.compile(r'struct\s+(D2GSPacket\w+)\s*\{(.*?)\n\};', re.S)
    fld = re.compile(r'/\*\s*(0x[0-9a-fA-F]+)\s*\*/\s*([A-Za-z_][\w:\* ]*?)\s+(\w+)\s*(\[[^\]]*\])?\s*;')
    for path in glob.glob(root + "/**/*.h", recursive=True) + glob.glob(root + "/**/*.cpp", recursive=True):
        try:
            txt = open(path, errors="replace").read()
        except OSError:
            continue
        for m in pat.finditer(txt):
            name, body = m.group(1), m.group(2)
            fields = [{"off": int(o, 16), "type": t.strip(), "name": n, "arr": a}
                      for o, t, n, a in fld.findall(body)]
            if fields and name not in structs:
                structs[name] = {"file": os.path.relpath(path, root), "fields": fields}
    return structs

WIDTH = {"byte": 1, "char": 1, "bool": 1, "ushort": 2, "short": 2, "uint16_t": 2, "int16_t": 2,
         "uint": 4, "int": 4, "uint32_t": 4, "int32_t": 4, "eD2UnitType": 4}
ZIG = {"byte": "u8", "char": "u8", "bool": "u8", "ushort": "u16", "short": "i16", "uint16_t": "u16",
       "int16_t": "i16", "uint": "u32", "int": "i32", "uint32_t": "u32", "int32_t": "i32",
       "eD2UnitType": "u32"}

def snake(n):
    """Hungarian-notation field name -> the name libd2 uses."""
    n = re.sub(r'^(n|w|dw|b|e|sz|p)(?=[A-Z])', '', n)
    n = re.sub(r'GUID', 'Guid', n)
    n = re.sub(r'ID$', 'Id', n)
    s = re.sub(r'(?<!^)(?=[A-Z])', '_', n).lower()
    s = s.replace('g_u_i_d', 'guid').replace('__', '_')
    if s in ("type", "error", "align", "test", "fn", "var", "const", "struct", "union", "enum",
             "opaque", "packed", "export", "pub", "and", "or", "return", "defer", "unreachable"):
        s = s + "_"
    return s

def zig_name(struct_name):
    m = re.match(r'D2GSPacketClt0x([0-9A-Fa-f]{2})_?(\w*)', struct_name)
    op = int(m.group(1), 16)
    label = m.group(2) or ("Cmd%02X" % op)
    return op, label[0].upper() + label[1:]

def dispatch_table(root):
    """opcode -> (handler symbol, packet struct name) from `NET_D2GS_SERVER_INCOMING[103]`.

    The DISPATCH TABLE is authoritative for which opcodes exist, not the struct names: several
    `D2GSPacketClt0xNN_*` structs are never dispatched (0x89 is a server-send struct that merely
    carries the `Clt` prefix), and several real commands (0x39, 0x42, 0x43, 0x45, 0x5F) have a
    handler but no struct of their own. Deriving the set from struct names gets both wrong — and
    happens to yield the same COUNT, which is exactly how it goes unnoticed.
    """
    src = open(os.path.join(root, "D2Game/Player/PlayerMsg.cpp"), errors="replace").read()
    i = src.index("NET_D2GS_SERVER_INCOMING[103] = {")
    handlers = re.findall(r"fpHandler = \*/ (?:&)?(\w+)", src[i:])[:103]

    # The declared parameter type is the struct for that opcode, whatever it is named.
    decls = {}
    for path in glob.glob(root + "/**/*.h", recursive=True):
        for m in re.finditer(r"(SCMD_0x[0-9A-Fa-f]{2}_\w+)\s*\([^)]*?(D2GSPacketClt\w+)\s*\*", 
                             open(path, errors="replace").read(), re.S):
            decls.setdefault(m.group(1), m.group(2))

    out = {}
    for op, h in enumerate(handlers):
        if h == "nullptr":
            continue
        out[op] = (h, decls.get(h))
    return out


def main():
    S = parse_structs(RECON)
    disp = dispatch_table(RECON)
    clt = {}
    for op, (sym, cname) in disp.items():
        m = re.match(r"SCMD_0x[0-9A-Fa-f]{2}_(\w+)", sym)
        label = m.group(1) if m else sym
        label = label[0].upper() + label[1:]
        v = S.get(cname) or {"file": "-", "fields": []}
        clt[op] = (label, dict(v, fields=list(v["fields"])), cname or "(no packet struct)")

    out = []
    w = out.append
    w("//! Client -> server game commands, 1.14d — every command the server dispatches.")
    w("//!")
    w("//! One struct per `SCMD_0xNN_*` handler, laid out from the `D2GSPacketClt0xNN_*` packet")
    w("//! structs recovered in Ghidra (session 62fbfe69, Game.exe 1.14d). Field offsets are the")
    w("//! recovered ones, so `encode` produces exactly the bytes the server's handler reads and")
    w("//! `decode` accepts exactly what it accepts. Generated — see scripts/gen_clt.py.")
    w("//!")
    w("//! Every packet exposes `OPCODE`, `SIZE` (wire size including the opcode byte), an")
    w("//! `encode(out) []u8` and a `decode(buf) !Self`. Trailing-string packets carry a `text`")
    w("//! slice instead of a fixed SIZE and expose `wireLen()`.")
    w("")
    w('const std = @import("std");')
    w("")
    w("pub const DecodeError = error{ ShortBuffer, WrongOpcode };")
    w("")

    # Several opcodes are passed the same struct (0x26/0x2A both take an ItemToCube, and four
    # dead stubs share one). The lowest opcode keeps the plain name; the rest carry theirs.
    seen = {}
    for op in sorted(clt):
        label, v, cname = clt[op]
        if label in seen:
            clt[op] = (label + ("%02X" % op), v, cname)
        seen[label] = op

    names = []
    for op in sorted(clt):
        label, v, cname = clt[op]
        fields = [f for f in v['fields'] if f['off'] != 0]  # 0x00 is nCmd, the opcode itself
        var = None
        fixed = []
        for f in fields:
            if f['arr']:
                var = f
                continue
            if f['type'] not in WIDTH:
                continue
            fixed.append(f)
        size = 1
        for f in fixed:
            size = max(size, f['off'] + WIDTH[f['type']])
        if var:
            size = max(size, var['off'])

        used = {}
        for f in fixed + ([var] if var else []):
            base = snake(f['name'])
            if base in used:
                f['name'] = f"{base}_at_{f['off']:02x}"
            used[base] = True

        names.append((op, label))
        w(f"/// 0x{op:02X} — SCMD_0x{op:02X}_{label}. `{cname}`.")
        w(f"pub const {label} = struct {{")
        w(f"    pub const OPCODE: u8 = 0x{op:02x};")
        if var is None:
            w(f"    pub const SIZE: usize = {size};")
        else:
            w(f"    pub const HEADER: usize = {size};")
        for f in fixed:
            w(f"    {snake(f['name'])}: {ZIG[f['type']]} = 0, // +0x{f['off']:02x}")
        if var is not None:
            w(f"    {snake(var['name'])}: []const u8 = \"\", // +0x{var['off']:02x}, NUL-terminated on the wire")
        w("")
        if var is None:
            if fixed:
                w("    pub fn encode(self: @This(), out: []u8) []u8 {")
            else:
                w("    pub fn encode(_: @This(), out: []u8) []u8 {")
            w("        std.debug.assert(out.len >= SIZE);")
            w("        @memset(out[0..SIZE], 0);")
            w("        out[0] = OPCODE;")
            for f in fixed:
                z, o, nm = ZIG[f['type']], f['off'], snake(f['name'])
                if WIDTH[f['type']] == 1:
                    w(f"        out[{o}] = self.{nm};")
                else:
                    w(f"        std.mem.writeInt({z}, out[{o}..][0..{WIDTH[f['type']]}], self.{nm}, .little);")
            w("        return out[0..SIZE];")
            w("    }")
            w("")
            w("    pub fn decode(buf: []const u8) DecodeError!@This() {")
            w("        if (buf.len < SIZE) return error.ShortBuffer;")
            w("        if (buf[0] != OPCODE) return error.WrongOpcode;")
            w("        return .{")
            for f in fixed:
                z, o, nm = ZIG[f['type']], f['off'], snake(f['name'])
                if WIDTH[f['type']] == 1:
                    w(f"            .{nm} = buf[{o}],")
                else:
                    w(f"            .{nm} = std.mem.readInt({z}, buf[{o}..][0..{WIDTH[f['type']]}], .little),")
            w("        };")
            w("    }")
        else:
            nm = snake(var['name'])
            w("    pub fn wireLen(self: @This()) usize {")
            w(f"        return HEADER + self.{nm}.len + 1;")
            w("    }")
            w("")
            w("    pub fn encode(self: @This(), out: []u8) []u8 {")
            w("        const n = self.wireLen();")
            w("        std.debug.assert(out.len >= n);")
            w("        @memset(out[0..HEADER], 0);")
            w("        out[0] = OPCODE;")
            for f in fixed:
                z, o, fn2 = ZIG[f['type']], f['off'], snake(f['name'])
                if WIDTH[f['type']] == 1:
                    w(f"        out[{o}] = self.{fn2};")
                else:
                    w(f"        std.mem.writeInt({z}, out[{o}..][0..{WIDTH[f['type']]}], self.{fn2}, .little);")
            w(f"        @memcpy(out[HEADER..][0..self.{nm}.len], self.{nm});")
            w(f"        out[HEADER + self.{nm}.len] = 0;")
            w("        return out[0..n];")
            w("    }")
            w("")
            w("    pub fn decode(buf: []const u8) DecodeError!@This() {")
            w("        if (buf.len < HEADER) return error.ShortBuffer;")
            w("        if (buf[0] != OPCODE) return error.WrongOpcode;")
            w("        const rest = buf[HEADER..];")
            w("        const end = std.mem.indexOfScalar(u8, rest, 0) orelse rest.len;")
            w("        return .{")
            for f in fixed:
                z, o, fn2 = ZIG[f['type']], f['off'], snake(f['name'])
                if WIDTH[f['type']] == 1:
                    w(f"            .{fn2} = buf[{o}],")
                else:
                    w(f"            .{fn2} = std.mem.readInt({z}, buf[{o}..][0..{WIDTH[f['type']]}], .little),")
            w(f"            .{nm} = rest[0..end],")
            w("        };")
            w("    }")
        w("};")
        w("")

    # The opcode -> name map, so a caller can label any command it sees.
    w("/// Every client->server opcode the 1.14d server dispatches, with the name of its handler.")
    w("pub fn name(op: u8) ?[]const u8 {")
    w("    return switch (op) {")
    for op, label in names:
        w(f"        0x{op:02x} => \"{label}\",")
    w("        else => null,")
    w("    };")
    w("}")
    w("")
    w("/// Wire size of a fixed-size command, or null when the command carries a trailing string")
    w("/// (its size depends on that string — build it with `encode`).")
    w("pub fn size(op: u8) ?usize {")
    w("    return switch (op) {")
    for op, label in names:
        _, v, _ = clt[op]
        has_var = any(f['arr'] for f in v['fields'])
        w(f"        0x{op:02x} => {'null' if has_var else f'{label}.SIZE'},")
    w("        else => null,")
    w("    };")
    w("}")
    w("")
    w("test \"every command round-trips through encode/decode\" {")
    w("    var buf: [512]u8 = undefined;")
    for op, label in names:
        _, v, _ = clt[op]
        has_var = any(f['arr'] for f in v['fields'])
        if has_var:
            continue
        w(f"    {{")
        w(f"        const p = {label}{{}};")
        w(f"        const wire = p.encode(&buf);")
        w(f"        try std.testing.expectEqual(@as(usize, {label}.SIZE), wire.len);")
        w(f"        try std.testing.expectEqual(@as(u8, 0x{op:02x}), wire[0]);")
        w(f"        try std.testing.expectEqual(p, try {label}.decode(wire));")
        w(f"    }}")
    w("}")
    w("")
    w("test \"opcode table covers every generated command\" {")
    w(f"    var n: usize = 0;")
    w("    var op: u16 = 0;")
    w("    while (op <= 0xff) : (op += 1) {")
    w("        if (name(@intCast(op)) != null) n += 1;")
    w("    }")
    w(f"    try std.testing.expectEqual(@as(usize, {len(names)}), n);")
    w("}")
    w("")

    w('test "the command set is the server\'s dispatch table, not the struct names" {')
    w("    // Regression: deriving the opcode set from `D2GSPacketClt0xNN_*` struct names produced")
    w("    // the right COUNT (91) but the wrong SET — it invented five commands the server never")
    w("    // dispatches and dropped five it does. Both halves are pinned here.")
    w("    for ([_]u8{ 0x39, 0x42, 0x43, 0x45, 0x5f }) |op| {")
    w("        if (name(op) == null) return error.MissingDispatchedCommand;")
    w("    }")
    w("    for ([_]u8{ 0x67, 0x68, 0x6b, 0x6d, 0x89 }) |op| {")
    w("        if (name(op) != null) return error.CommandIsNotDispatched;")
    w("    }")
    w("    try std.testing.expectEqualStrings(\"SyncPosition\", name(0x5f).?);")
    w("    try std.testing.expectEqualStrings(\"StaffInOrifice1\", name(0x42).?);")
    w("}")
    w("")

    # Cross-check against the hand-written subset: generation is only worth trusting if it
    # reproduces the bytes the reviewed, capture-verified structs already produce.
    w('test "generated commands match the hand-written cs.zig byte-for-byte" {')
    w('    const cs = @import("cs.zig");')
    w("    var a: [64]u8 = undefined;")
    w("    var b: [64]u8 = undefined;")
    w("    try std.testing.expectEqualSlices(u8,")
    w("        cs.WalkToLocation.encode(.{ .x = 5000, .y = 6001 }, &a),")
    w("        WalkToLocation.encode(.{ .x = 5000, .y = 6001 }, &b));")
    w("    try std.testing.expectEqualSlices(u8,")
    w("        cs.RunToLocation.encode(.{ .x = 1, .y = 2 }, &a),")
    w("        RunToLocation.encode(.{ .x = 1, .y = 2 }, &b));")
    w("    try std.testing.expectEqualSlices(u8,")
    w("        cs.WalkToEntity.encode(.{ .unit_type = 1, .guid = 0xDEADBEEF }, &a),")
    w("        WalkToEntity.encode(.{ .unit_type = 1, .unit_guid = 0xDEADBEEF }, &b));")
    w("    try std.testing.expectEqualSlices(u8,")
    w("        cs.InteractWithEntity.encode(.{ .unit_type = 1, .guid = 7 }, &a),")
    w("        InteractWithEntity.encode(.{ .unit_type = 1, .guid = 7 }, &b));")
    w("}")
    w("")

    open(sys.argv[1], "w").write("\n".join(out))
    print(f"generated {len(names)} client->server commands -> {sys.argv[1]}")

main()
