#!/usr/bin/env python3
"""Generate d2-net's server->client opcode table from the engine's own dispatch table.

`NET_D2GS_CLIENT_INCOMING` (0x007114D0, 175 entries) pairs every S->C opcode with the handler the
client runs for it and the size it expects. Reading the table rather than transcribing names is the
point: several handler symbols are misnomers (0x19..0x1F are called "ItemPageUpdate" but the body
calls STATLIST_SetUnitStat), and a generated table cannot drift from the binary the way a
hand-maintained list does.
"""
import os, re, sys

RECON = os.environ.get("D2_RECON", os.path.expanduser("~/code/CPP/diablo-2"))


def parse_table(path):
    src = open(path, errors="replace").read()
    i = src.index("NET_D2GS_CLIENT_INCOMING[175] = {")
    entries = re.findall(
        r"fpIncomingHandler = \*/ (?:&)?(\w+).*?nExpectedSize = \*/ (-?\w+).*?fpIncomingHandlerUnit = \*/ (?:&)?(\w+)",
        src[i:], re.S)[:175]
    out = []
    for idx, (h, sz, hu) in enumerate(entries):
        sym = hu if hu != "nullptr" else h
        m = re.match(r"NET_D2GS_CLIENT_(?:Incoming|Recv)?0x[0-9A-Fa-f]{2}(?:to0x[0-9A-Fa-f]{2})?_?(\w*)", sym)
        label = m.group(1) if m and m.group(1) else re.sub(r"^NET_D2GS_CLIENT_", "", sym)
        try:
            size = int(sz, 16) if sz.startswith("0x") else int(sz)
        except ValueError:
            size = -1
        if size > 0xFFFF:      # the table stores variable-size as -1
            size = -1
        out.append((idx, label or ("Op%02X" % idx), size, sym))
    return out


def main():
    rows = parse_table(os.path.join(RECON, "D2Game/Game/SCmd.cpp"))
    w = [].append
    o = []
    w = o.append
    w("//! Server -> client opcode table, 1.14d — the whole 175-entry dispatch space.")
    w("//!")
    w("//! Generated from `NET_D2GS_CLIENT_INCOMING` @0x007114D0 (Ghidra session 62fbfe69) via")
    w("//! scripts/gen_sc_table.py. `handler` is the client function the engine actually runs for")
    w("//! the opcode, which is the honest name for it — several of the symbols in the binary are")
    w("//! misnomers, and this table records what the code does, not what the label claims.")
    w("")
    w('const std = @import("std");')
    w("")
    w("pub const Entry = struct {")
    w("    /// The client handler the engine dispatches to.")
    w("    handler: []const u8,")
    w("    /// The size THIS TABLE's entry declares. Note it is not the framing size: the engine")
    w("    /// frames with `NET_D2GS_CLIENT_INCOMING_SIZE` @0x730AE8 (`sc.SC_SIZE`, and")
    w("    /// `sc.packetSize` for the variable ones), and the two disagree on 0x17 and 0x80 —")
    w("    /// both dead opcodes the framing table marks invalid. Frame with `sc.packetSize`;")
    w("    /// this field is only what the handler entry claims to expect.")
    w("    expected_size: i32,")
    w("};")
    w("")
    w(f"pub const COUNT = {len(rows)};")
    w("")
    w("/// Every S->C opcode the 1.14d client dispatches, indexed by opcode.")
    w("pub const TABLE = [COUNT]Entry{")
    for idx, label, size, sym in rows:
        w(f'    .{{ .handler = "{label}", .expected_size = {size} }}, // 0x{idx:02x} {sym}')
    w("};")
    w("")
    w("/// The handler name for an opcode, or null when the opcode is outside the table.")
    w("pub fn handler(op: u8) ?[]const u8 {")
    w("    if (op >= COUNT) return null;")
    w("    return TABLE[op].handler;")
    w("}")
    w("")
    w('test "the table covers the engine\'s whole dispatch space" {')
    w(f"    try std.testing.expectEqual(@as(usize, {len(rows)}), TABLE.len);")
    w('    try std.testing.expectEqualStrings("LoadAct", TABLE[0x03].handler);')
    w("    try std.testing.expectEqual(@as(i32, 12), TABLE[0x03].expected_size);")
    w("    try std.testing.expect(handler(0xff) == null);")
    w("}")
    w("")
    open(sys.argv[1], "w").write("\n".join(o))
    print(f"generated {len(rows)} server->client opcodes -> {sys.argv[1]}")


main()
