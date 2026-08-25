//! The install script Blizzard's installers carry, and the plan it describes.
//!
//! An installer payload is an MPQ — the "Tome" — holding both the files to install and, at
//! `InstallCD\InstallerFileList\InstallerFileList.xml`, the script saying where each one goes.
//! The script is a small XML tree: `<replace>` defines a symbol, `<if true_condition="...">`
//! selects a platform or language branch, and the operations sit under `<target>` inside
//! `<repack_into>` containers.
//!
//! This turns that script into a flat list of operations for a given platform and language.
//! Nothing here touches a file or an archive: the caller reads members out of the Tome and
//! writes them, which keeps the decision of what to install separate from the doing of it.

const std = @import("std");

pub const Error = error{ BadManifest, OutOfMemory };

pub const Platform = enum { win32, macos };

pub const Options = struct {
    platform: Platform = .win32,
    /// The language condition to take, spelled as the script spells it: "English", "German",
    /// "French", "Spanish", "Italian", "Polish", "Korean", "SimplifiedChinese",
    /// "TraditionalChinese".
    language: []const u8 = "English",
};

pub const Op = union(enum) {
    /// Write a member of the archive out as a file.
    extract: File,
    /// Add a member to an archive being installed. Needs a writer, which reading does not.
    add_to_archive: struct { container: []const u8, file: File },
    create_folder: []const u8,
    /// Remove a file the payload is replacing. The expansion's script does this; the base
    /// game's never does.
    delete: []const u8,
    /// Store an encoded value — the CD key, the account name — inside an installed file.
    encrypt: struct { object: []const u8, into: []const u8 },
    registry: struct { where: []const u8, key: []const u8, value: []const u8 },
    shortcut: struct { path: []const u8, name: []const u8 },
    directx: struct { file: []const u8, minimum_version: []const u8 },
    add_remove_programs: []const u8,

    pub const File = struct {
        /// Member name inside the archive. Null when the script names no source, which happens
        /// for the few files the installer carries itself rather than in the Tome.
        from: ?[]const u8,
        to: []const u8,
        /// The size the script claims, worth checking what comes out of the archive against.
        size: ?u64 = null,
    };
};

pub const Plan = struct {
    ops: []Op,
    /// Every symbol the script defined along the way, after expansion.
    symbols: std.StringHashMapUnmanaged([]const u8),

    pub fn deinit(self: *Plan, gpa: std.mem.Allocator) void {
        gpa.free(self.ops);
        self.symbols.deinit(gpa);
        self.* = undefined;
    }

    /// Only the operations that write a plain file, which is what produces a playable directory.
    pub fn files(self: Plan, gpa: std.mem.Allocator) ![]Op.File {
        var out: std.ArrayList(Op.File) = .empty;
        for (self.ops) |op| switch (op) {
            .extract => |f| try out.append(gpa, f),
            else => {},
        };
        return out.toOwnedSlice(gpa);
    }
};

/// The canonical name of the script inside the Tome.
pub const manifest_path = "InstallCD\\InstallerFileList\\InstallerFileList.xml";

pub fn parse(gpa: std.mem.Allocator, xml: []const u8, options: Options) Error!Plan {
    var p: Xml = .{ .src = xml, .gpa = gpa };
    const root = (p.element() catch return Error.BadManifest) orelse return Error.BadManifest;

    var b: Builder = .{ .gpa = gpa, .options = options };
    try b.walk(root, null);
    return .{ .ops = try b.ops.toOwnedSlice(gpa), .symbols = b.symbols };
}

const Builder = struct {
    gpa: std.mem.Allocator,
    options: Options,
    ops: std.ArrayList(Op) = .empty,
    symbols: std.StringHashMapUnmanaged([]const u8) = .empty,

    /// `{Name}` stands for a symbol an earlier `<replace>` defined.
    fn expand(b: *Builder, text: []const u8) Error![]const u8 {
        if (std.mem.indexOfScalar(u8, text, '{') == null) return text;
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < text.len) {
            if (text[i] == '{') {
                if (std.mem.indexOfScalarPos(u8, text, i, '}')) |end| {
                    if (b.symbols.get(text[i + 1 .. end])) |v| {
                        try out.appendSlice(b.gpa, v);
                        i = end + 1;
                        continue;
                    }
                }
            }
            try out.append(b.gpa, text[i]);
            i += 1;
        }
        return out.toOwnedSlice(b.gpa);
    }

    fn holds(b: *Builder, name: []const u8) bool {
        if (std.ascii.eqlIgnoreCase(name, "Win32")) return b.options.platform == .win32;
        if (std.ascii.eqlIgnoreCase(name, "MacOS")) return b.options.platform == .macos;
        return std.ascii.eqlIgnoreCase(name, b.options.language);
    }

    fn file(b: *Builder, node: *Node) Error!Op.File {
        return .{
            .from = if (node.attr("from")) |f| try b.expand(f) else null,
            .to = try b.expand(node.attr("to") orelse ""),
            .size = if (node.attr("size")) |s| std.fmt.parseInt(u64, s, 10) catch null else null,
        };
    }

    fn walk(b: *Builder, node: *Node, container: ?[]const u8) Error!void {
        for (node.kids) |kid| {
            const t = kid.tag;
            if (std.mem.eql(u8, t, "replace")) {
                const sym = kid.attr("symbol") orelse continue;
                try b.symbols.put(b.gpa, sym, try b.expand(kid.attr("with") orelse continue));
            } else if (std.mem.eql(u8, t, "if")) {
                const taken = b.holds(kid.attr("true_condition") orelse "");
                var had_branch = false;
                for (kid.kids) |br| {
                    if (std.mem.eql(u8, br.tag, "then")) {
                        had_branch = true;
                        if (taken) try b.walk(br, container);
                    } else if (std.mem.eql(u8, br.tag, "else")) {
                        had_branch = true;
                        if (!taken) try b.walk(br, container);
                    }
                }
                // Children sitting directly under <if>, with no <then>, belong to the true side.
                if (!had_branch and taken) try b.walk(kid, container);
            } else if (std.mem.eql(u8, t, "repack_into")) {
                const ty = kid.attr("type") orelse "file";
                const into: ?[]const u8 = if (std.mem.eql(u8, ty, "file"))
                    null
                else
                    try b.expand(kid.attr("container") orelse ty);
                try b.walk(kid, into);
            } else if (std.mem.eql(u8, t, "repack")) {
                const f = try b.file(kid);
                try b.ops.append(b.gpa, if (container) |c|
                    .{ .add_to_archive = .{ .container = c, .file = f } }
                else
                    .{ .extract = f });
            } else if (std.mem.eql(u8, t, "delete")) {
                try b.ops.append(b.gpa, .{ .delete = try b.expand(kid.attr("path") orelse kid.attr("target_path") orelse "") });
            } else if (std.mem.eql(u8, t, "create_folder")) {
                try b.ops.append(b.gpa, .{ .create_folder = try b.expand(kid.attr("path") orelse "") });
            } else if (std.mem.eql(u8, t, "encrypt")) {
                try b.ops.append(b.gpa, .{ .encrypt = .{
                    .object = try b.expand(kid.attr("object") orelse ""),
                    .into = try b.expand(kid.attr("into") orelse ""),
                } });
                try b.walk(kid, container);
            } else if (std.mem.eql(u8, t, "registry_key")) {
                try b.ops.append(b.gpa, .{ .registry = .{
                    .where = try b.expand(kid.attr("where") orelse ""),
                    .key = try b.expand(kid.attr("key_name") orelse ""),
                    .value = try b.expand(kid.attr("value_name") orelse ""),
                } });
                try b.walk(kid, container);
            } else if (std.mem.eql(u8, t, "create_shortcut")) {
                try b.ops.append(b.gpa, .{ .shortcut = .{
                    .path = try b.expand(kid.attr("path") orelse ""),
                    .name = try b.expand(kid.attr("shortcut_name") orelse ""),
                } });
                try b.walk(kid, container);
            } else if (std.mem.eql(u8, t, "install_directx")) {
                try b.ops.append(b.gpa, .{ .directx = .{
                    .file = try b.expand(kid.attr("cd_file") orelse ""),
                    .minimum_version = kid.attr("minimum_version") orelse "",
                } });
            } else if (std.mem.eql(u8, t, "add_remove_programs")) {
                try b.ops.append(b.gpa, .{ .add_remove_programs = try b.expand(kid.attr("product") orelse "") });
            } else {
                try b.walk(kid, container);
            }
        }
    }
};

// ── just enough XML for this script ──────────────────────────────────────────────────────────

const Attr = struct { name: []const u8, value: []const u8 };

const Node = struct {
    tag: []const u8,
    attrs: []Attr = &.{},
    kids: []*Node = &.{},

    fn attr(self: *const Node, name: []const u8) ?[]const u8 {
        for (self.attrs) |a| if (std.mem.eql(u8, a.name, name)) return a.value;
        return null;
    }
};

const Xml = struct {
    src: []const u8,
    at: usize = 0,
    gpa: std.mem.Allocator,

    fn ws(x: *Xml) void {
        while (x.at < x.src.len and std.ascii.isWhitespace(x.src[x.at])) x.at += 1;
    }

    /// Declarations, comments and doctypes carry no operations.
    fn skipNoise(x: *Xml) void {
        // A UTF-8 byte-order mark is not whitespace and not a tag; the expansion's script
        // carries one where the base game's does not.
        if (std.mem.startsWith(u8, x.src[x.at..], "\xef\xbb\xbf")) x.at += 3;
        while (true) {
            x.ws();
            const rest = x.src[x.at..];
            if (std.mem.startsWith(u8, rest, "<!--")) {
                x.at = (std.mem.indexOfPos(u8, x.src, x.at, "-->") orelse x.src.len -| 3) + 3;
            } else if (std.mem.startsWith(u8, rest, "<?") or std.mem.startsWith(u8, rest, "<!")) {
                x.at = (std.mem.indexOfScalarPos(u8, x.src, x.at, '>') orelse x.src.len -| 1) + 1;
            } else return;
        }
    }

    fn element(x: *Xml) Error!?*Node {
        x.skipNoise();
        if (x.at >= x.src.len or x.src[x.at] != '<') return null;
        if (std.mem.startsWith(u8, x.src[x.at..], "</")) return null;
        x.at += 1;

        const start = x.at;
        while (x.at < x.src.len and !std.ascii.isWhitespace(x.src[x.at]) and
            x.src[x.at] != '>' and x.src[x.at] != '/') x.at += 1;
        const node = try x.gpa.create(Node);
        node.* = .{ .tag = x.src[start..x.at] };

        var attrs: std.ArrayList(Attr) = .empty;
        while (true) {
            x.ws();
            if (x.at >= x.src.len or x.src[x.at] == '>' or x.src[x.at] == '/') break;
            const k0 = x.at;
            while (x.at < x.src.len and x.src[x.at] != '=' and
                !std.ascii.isWhitespace(x.src[x.at]) and x.src[x.at] != '>') x.at += 1;
            const key = x.src[k0..x.at];
            x.ws();
            if (x.at < x.src.len and x.src[x.at] == '=') x.at += 1;
            x.ws();
            var value: []const u8 = "";
            if (x.at < x.src.len and (x.src[x.at] == '"' or x.src[x.at] == '\'')) {
                const q = x.src[x.at];
                x.at += 1;
                const v0 = x.at;
                while (x.at < x.src.len and x.src[x.at] != q) x.at += 1;
                value = x.src[v0..x.at];
                if (x.at < x.src.len) x.at += 1;
            }
            if (key.len != 0) try attrs.append(x.gpa, .{ .name = key, .value = value });
        }
        node.attrs = try attrs.toOwnedSlice(x.gpa);

        if (x.at < x.src.len and x.src[x.at] == '/') {
            x.at = @min(x.at + 2, x.src.len);
            return node;
        }
        if (x.at < x.src.len) x.at += 1;

        var kids: std.ArrayList(*Node) = .empty;
        while (x.at < x.src.len) {
            x.skipNoise();
            if (x.at >= x.src.len) break;
            if (std.mem.startsWith(u8, x.src[x.at..], "</")) {
                x.at = (std.mem.indexOfScalarPos(u8, x.src, x.at, '>') orelse x.src.len -| 1) + 1;
                break;
            }
            if (x.src[x.at] == '<') {
                if (try x.element()) |kid| {
                    try kids.append(x.gpa, kid);
                    continue;
                }
            }
            x.at += 1;
        }
        node.kids = try kids.toOwnedSlice(x.gpa);
        return node;
    }
};

// ── tests ────────────────────────────────────────────────────────────────────────────────────

const testing = std.testing;

const sample =
    \\<install>
    \\  <replace symbol="Tome1" with="Installer Tome.mpq"/>
    \\  <replace symbol="Dir" with="Common"/>
    \\  <disc name="d" with_file="{Tome1}">
    \\    <archive input="#INPUT#" path="{Tome1}">
    \\      <if true_condition="Win32">
    \\        <then>
    \\          <target location="user">
    \\            <repack_into type="file">
    \\              <repack from="{Dir}\d2data.mpq" to="d2data.mpq" size="12"/>
    \\            </repack_into>
    \\            <repack_into type="mpq" container="d2data.mpq">
    \\              <repack from="PC-100\Fog.dll" to="Fog.dll" size="7"/>
    \\            </repack_into>
    \\          </target>
    \\        </then>
    \\        <else>
    \\          <target location="user">
    \\            <repack_into type="file">
    \\              <repack from="{Dir}\d2data.mpq" to="Diablo II Game Data"/>
    \\            </repack_into>
    \\          </target>
    \\        </else>
    \\      </if>
    \\    </archive>
    \\  </disc>
    \\</install>
;

test "the win32 branch installs files and defers archive members" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const plan_ = try parse(gpa, sample, .{ .platform = .win32 });
    try testing.expectEqual(@as(usize, 2), plan_.ops.len);

    try testing.expectEqualStrings("Common\\d2data.mpq", plan_.ops[0].extract.from.?);
    try testing.expectEqualStrings("d2data.mpq", plan_.ops[0].extract.to);
    try testing.expectEqual(@as(u64, 12), plan_.ops[0].extract.size.?);

    // A member bound for an archive is not a file, and says which archive.
    try testing.expectEqualStrings("d2data.mpq", plan_.ops[1].add_to_archive.container);
    try testing.expectEqualStrings("Fog.dll", plan_.ops[1].add_to_archive.file.to);

    const only_files = try plan_.files(gpa);
    try testing.expectEqual(@as(usize, 1), only_files.len);
}

test "the macos branch installs the same member under its own name" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const plan_ = try parse(gpa, sample, .{ .platform = .macos });
    try testing.expectEqual(@as(usize, 1), plan_.ops.len);
    try testing.expectEqualStrings("Diablo II Game Data", plan_.ops[0].extract.to);
    try testing.expectEqual(@as(?u64, null), plan_.ops[0].extract.size);
}

test "symbols expand, including inside a source path" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const plan_ = try parse(gpa, sample, .{});
    try testing.expectEqualStrings("Installer Tome.mpq", plan_.symbols.get("Tome1").?);
    try testing.expect(std.mem.startsWith(u8, plan_.ops[0].extract.from.?, "Common\\"));
}

test "a language condition selects its own branch" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const xml =
        \\<install>
        \\ <if true_condition="German"><then><replace symbol="L" with="de"/></then>
        \\ <else><replace symbol="L" with="en"/></else></if>
        \\</install>
    ;
    const de = try parse(gpa, xml, .{ .language = "German" });
    try testing.expectEqualStrings("de", de.symbols.get("L").?);
    const en = try parse(gpa, xml, .{ .language = "English" });
    try testing.expectEqualStrings("en", en.symbols.get("L").?);
}

test "malformed input is an error, not a crash" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(Error.BadManifest, parse(arena.allocator(), "not xml at all", .{}));
    // truncated mid-element
    _ = parse(arena.allocator(), "<install><repack from=\"a\" to=", .{}) catch {};
}

test "a byte-order mark before the declaration does not defeat the parser" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const xml = "\xef\xbb\xbf<?xml version=\"1.0\"?>\n" ++
        "<install><replace symbol=\"A\" with=\"b\"/></install>";
    const plan_ = try parse(gpa, xml, .{});
    try testing.expectEqualStrings("b", plan_.symbols.get("A").?);
}

test "the expansion's extra elements are understood, not walked past" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    // multipass_install/pass only group work; delete is an operation in its own right.
    const xml =
        \\<install>
        \\ <multipass_install>
        \\  <pass>
        \\   <target location="user">
        \\    <delete path="old.dll"/>
        \\    <repack_into type="file"><repack from="a" to="b"/></repack_into>
        \\   </target>
        \\  </pass>
        \\ </multipass_install>
        \\</install>
    ;
    const plan_ = try parse(gpa, xml, .{});
    try testing.expectEqual(@as(usize, 2), plan_.ops.len);
    try testing.expectEqualStrings("old.dll", plan_.ops[0].delete);
    try testing.expectEqualStrings("b", plan_.ops[1].extract.to);
}
