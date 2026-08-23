//! Diablo II bitmap fonts: a `.tbl` of glyph metrics beside a `.dc6` of glyph images.
//!
//! `data/local/font/<lang>/<name>.tbl` and `.dc6` — the game builds both paths from the same font
//! name, so they always come in pairs. The table is what makes the font proportional: the DC6's
//! frames are all one cell size, and the width to advance by is per glyph.
//!
//! The table is sorted by character code and the game binary-searches it, so a code that is not
//! there is not an error — it falls back to a fixed entry rather than failing.
const std = @import("std");
const dc6 = @import("dc6.zig");
const palette = @import("palette.zig");
const canvas_mod = @import("canvas.zig");

pub const Error = error{ BadFontTable, ShortFontTable };

/// The fonts, by the id the game selects them with. This is `aFontNames` out of Game.exe, in its
/// own order — which is not size order, and is the same numbering `D2WIN_SetTextSize` takes.
pub const Id = enum(u8) {
    font8 = 0,
    font16 = 1,
    font30 = 2,
    font42 = 3,
    formal10 = 4,
    /// A SECOND Font16. `aFontNames[5]` in Game.exe points at another copy of the same name, not
    /// at FontFormal12 — which does not appear in the table at all. A style record that asks for
    /// font 5 gets Font16, and calling it something else here means loading a file that is not
    /// what the game would have loaded.
    font16_again = 5,
    font6 = 6,
    font24 = 7,
    formal11 = 8,
    exocet10 = 9,
    ridiculous = 10,
    exocet8 = 11,
    really_the_last_sucker = 12,
    in_game_chat = 13,

    /// The file name, which is also what the `.tbl` and `.dc6` are both called.
    pub fn fileName(id: Id) []const u8 {
        return switch (id) {
            .font8 => "Font8",
            .font16 => "Font16",
            .font30 => "Font30",
            .font42 => "Font42",
            .formal10 => "FontFormal10",
            .font16_again => "Font16",
            .font6 => "Font6",
            .font24 => "Font24",
            .formal11 => "FontFormal11",
            .exocet10 => "FontExocet10",
            .ridiculous => "FontRidiculous",
            .exocet8 => "FontExocet8",
            .really_the_last_sucker => "ReallyTheLastSucker",
            .in_game_chat => "FontInGameChat",
        };
    }
};

pub const signature = "Woo!";

/// 12 bytes: the signature, a version, the glyph count, and two defaults.
pub const header_len = 12;
pub const entry_len = 14;

pub const Glyph = struct {
    code: u16,
    /// How far to advance after drawing it. This is the whole reason the table exists.
    width: u8,
    height: u8,
    /// Which DC6 frame holds the picture. Usually the code itself, but not promised to be.
    frame: u16,
};

pub const Table = struct {
    /// Sorted by `code`, which is what lets a lookup binary-search the way the game does.
    glyphs: []Glyph,

    pub fn deinit(self: *Table, gpa: std.mem.Allocator) void {
        gpa.free(self.glyphs);
        self.* = undefined;
    }

    pub fn find(self: *const Table, code: u16) ?Glyph {
        var lo: usize = 0;
        var hi: usize = self.glyphs.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const g = self.glyphs[mid];
            if (g.code == code) return g;
            if (code < g.code) hi = mid else lo = mid + 1;
        }
        return null;
    }
};

pub fn parseTable(gpa: std.mem.Allocator, bytes: []const u8) !Table {
    if (bytes.len < header_len) return Error.ShortFontTable;
    if (!std.mem.eql(u8, bytes[0..4], signature)) return Error.BadFontTable;

    const count = std.mem.readInt(u16, bytes[8..10], .little);
    const need = header_len + @as(usize, count) * entry_len;
    if (bytes.len < need) return Error.ShortFontTable;

    const glyphs = try gpa.alloc(Glyph, count);
    errdefer gpa.free(glyphs);

    for (glyphs, 0..) |*g, i| {
        const e = bytes[header_len + i * entry_len ..][0..entry_len];
        g.* = .{
            .code = std.mem.readInt(u16, e[0..2], .little),
            .width = e[3],
            .height = e[4],
            .frame = std.mem.readInt(u16, e[8..10], .little),
        };
    }
    return .{ .glyphs = glyphs };
}

/// A table and its images together, which is the only useful form.
pub const Font = struct {
    table: Table,
    sheet: dc6.Dc6,

    pub fn deinit(self: *Font, gpa: std.mem.Allocator) void {
        self.table.deinit(gpa);
        self.sheet.deinit();
        self.* = undefined;
    }

    /// How wide `text` renders. Characters the font does not have contribute nothing, which
    /// matches the game drawing nothing for them.
    pub fn measure(self: *const Font, text: []const u8) u32 {
        var w: u32 = 0;
        for (text) |c| {
            const g = self.table.find(c) orelse continue;
            w += g.width;
        }
        return w;
    }

    /// The tallest glyph, which is what a line of this font occupies.
    pub fn lineHeight(self: *const Font) u32 {
        var h: u32 = 0;
        for (self.sheet.frames) |f| h = @max(h, f.height);
        return h;
    }

    /// Draw `text` with its BASELINE at `y` — the glyphs sit above it, not below.
    ///
    /// That is the game's convention, not a choice: `D2WINFONT_DrawWideString` hands the line's `y`
    /// straight to the same image blit everything else uses, and that blit treats `y` as the bottom
    /// row. A form's text box records the baseline for the same reason its images record their
    /// bottom.
    ///
    /// Returns where the next character would go.
    ///
    /// `shift` is a `pl2` text-colour table, or null to draw the glyphs' own colours. Diablo II
    /// has no tinting: a red string is the same glyph images drawn through the red index map.
    pub fn draw(
        self: *const Font,
        canvas: *canvas_mod.Canvas,
        pal: *const palette.Palette,
        x: i32,
        y: i32,
        text: []const u8,
        shift: ?[]const u8,
    ) i32 {
        var cx = x;
        for (text) |c| {
            const g = self.table.find(c) orelse continue;
            if (g.frame < self.sheet.frames.len) {
                const f = &self.sheet.frames[g.frame];
                const top = y - @as(i32, @intCast(f.height));
                canvas.blitIndicesShifted(f.indices, f.width, f.height, pal, cx, top, .solid, shift);
            }
            cx += g.width;
        }
        return cx;
    }

    /// Where one wrapped line ends and the next begins. They are not the same offset: the space a
    /// break lands on belongs to neither line.
    pub const LineBreak = struct {
        take: usize,
        next: usize,
    };

    /// Break `text` at the last place that still fits in `width`.
    ///
    /// `D2WINTEXTBOX_WordWrapAndSetText` @0x4fcda0 walks forward a character at a time, remembering
    /// the last space it passed, and stops on the first prefix that measures `width` or MORE — so a
    /// line exactly the box's width already wraps. If it passed a space it breaks there; if it did
    /// not, the word is wider than the box and it breaks mid-word at the last character that fit.
    /// It hands the tail to `SetText` @0x4fc8f0, which strips leading whitespace, so the space at a
    /// break is dropped rather than starting the next line.
    ///
    /// The engine returns an empty first line when one glyph is wider than the box, and then
    /// recurses on the same string until the stack runs out. A character always goes out here.
    pub fn breakLine(self: *const Font, text: []const u8, width: u32) LineBreak {
        var fits: usize = 0;
        var last_space: usize = 0;
        while (fits < text.len) {
            if (text[fits] == ' ') last_space = fits;
            if (self.measure(text[0 .. fits + 1]) >= width) {
                if (last_space != 0) {
                    var next = last_space;
                    while (next < text.len and text[next] == ' ') next += 1;
                    return .{ .take = last_space, .next = next };
                }
                const take = @max(fits, 1);
                return .{ .take = take, .next = take };
            }
            fits += 1;
        }
        return .{ .take = text.len, .next = text.len };
    }

    /// How many lines `text` occupies once broken to `width`. Never zero, so an empty message still
    /// takes the row the game gives it.
    pub fn wrappedLines(self: *const Font, text: []const u8, width: u32) usize {
        var rest = trimLeadingSpace(text);
        var n: usize = 0;
        while (rest.len != 0) {
            const br = self.breakLine(rest, width);
            rest = trimLeadingSpace(rest[br.next..]);
            n += 1;
        }
        return @max(n, 1);
    }

    fn trimLeadingSpace(text: []const u8) []const u8 {
        var rest = text;
        while (rest.len != 0 and rest[0] == ' ') rest = rest[1..];
        return rest;
    }

    /// Draw `text` broken to fit `width`, each line left-aligned at `x`. Returns the baseline the
    /// next line would use.
    pub fn drawWrapped(
        self: *const Font,
        canvas: *canvas_mod.Canvas,
        pal: *const palette.Palette,
        x: i32,
        y: i32,
        width: u32,
        line_height: u32,
        text: []const u8,
        shift: ?[]const u8,
    ) i32 {
        var baseline = y;
        var rest = trimLeadingSpace(text);
        while (rest.len != 0) {
            const br = self.breakLine(rest, width);
            _ = self.draw(canvas, pal, x, baseline, rest[0..br.take], shift);
            baseline += @intCast(line_height);
            rest = trimLeadingSpace(rest[br.next..]);
        }
        return baseline;
    }

    /// Draw `text` broken to fit `width`, each line centred on `cx`. Returns the baseline the next
    /// line would use.
    pub fn drawWrappedCentered(
        self: *const Font,
        canvas: *canvas_mod.Canvas,
        pal: *const palette.Palette,
        cx: i32,
        y: i32,
        width: u32,
        line_height: u32,
        text: []const u8,
        shift: ?[]const u8,
    ) i32 {
        var baseline = y;
        var rest = trimLeadingSpace(text);
        while (rest.len != 0) {
            const br = self.breakLine(rest, width);
            self.drawCentered(canvas, pal, cx, baseline, rest[0..br.take], shift);
            baseline += @intCast(line_height);
            rest = trimLeadingSpace(rest[br.next..]);
        }
        return baseline;
    }

    /// Draw centred on `cx`, which is how every title and button label in the front end is placed.
    pub fn drawCentered(
        self: *const Font,
        canvas: *canvas_mod.Canvas,
        pal: *const palette.Palette,
        cx: i32,
        y: i32,
        text: []const u8,
        shift: ?[]const u8,
    ) void {
        const w: i32 = @intCast(self.measure(text));
        _ = self.draw(canvas, pal, cx - @divTrunc(w, 2), y, text, shift);
    }
};

const testing = std.testing;

fn buildTable(gpa: std.mem.Allocator, entries: []const [4]u16) ![]u8 {
    const buf = try gpa.alloc(u8, header_len + entries.len * entry_len);
    @memset(buf, 0);
    @memcpy(buf[0..4], signature);
    std.mem.writeInt(u16, buf[8..10], @intCast(entries.len), .little);
    for (entries, 0..) |e, i| {
        const at = header_len + i * entry_len;
        std.mem.writeInt(u16, buf[at..][0..2], e[0], .little);
        buf[at + 3] = @intCast(e[1]);
        buf[at + 4] = @intCast(e[2]);
        std.mem.writeInt(u16, buf[at + 8 ..][0..2], e[3], .little);
    }
    return buf;
}

test "glyph metrics come off the entry at the offsets the game reads" {
    const gpa = testing.allocator;
    // Exactly what font16.tbl holds for space, 'A', 'W' and 'i' — proportional, as advertised.
    const raw = try buildTable(gpa, &.{
        .{ ' ', 8, 10, ' ' },
        .{ 'A', 12, 10, 'A' },
        .{ 'W', 16, 10, 'W' },
        .{ 'i', 4, 10, 'i' },
    });
    defer gpa.free(raw);

    var t = try parseTable(gpa, raw);
    defer t.deinit(gpa);

    try testing.expectEqual(@as(u8, 8), t.find(' ').?.width);
    try testing.expectEqual(@as(u8, 12), t.find('A').?.width);
    try testing.expectEqual(@as(u8, 16), t.find('W').?.width);
    try testing.expectEqual(@as(u8, 4), t.find('i').?.width);
    try testing.expectEqual(@as(u16, 'W'), t.find('W').?.frame);
}

test "a character the font does not have is absent, not an error" {
    const gpa = testing.allocator;
    const raw = try buildTable(gpa, &.{ .{ 'A', 12, 10, 'A' }, .{ 'B', 12, 10, 'B' } });
    defer gpa.free(raw);

    var t = try parseTable(gpa, raw);
    defer t.deinit(gpa);
    try testing.expect(t.find('Z') == null);
}

/// A font that measures and nothing else: every letter 10 wide, the space 10 too, so a width in
/// pixels reads as a character count. Wrapping only ever asks the table, never the sheet.
fn measureOnlyFont(gpa: std.mem.Allocator) !Font {
    var entries: [27][4]u16 = undefined;
    entries[0] = .{ ' ', 10, 10, 0 };
    for (entries[1..], 0..) |*e, i| e.* = .{ @intCast('a' + i), 10, 10, 0 };

    const raw = try buildTable(gpa, &entries);
    defer gpa.free(raw);
    return .{ .table = try parseTable(gpa, raw), .sheet = .{ .frames = &.{}, .allocator = gpa } };
}

test "a wrapped line breaks at the last space that fits" {
    const gpa = testing.allocator;
    var f = try measureOnlyFont(gpa);
    defer f.table.deinit(gpa);

    // "aaa bbb ccc" at 80px: "aaa bbb" is 70 and fits, "aaa bbb " is 80 and does not.
    const br = f.breakLine("aaa bbb ccc", 80);
    try testing.expectEqualStrings("aaa bbb", "aaa bbb ccc"[0..br.take]);
    try testing.expectEqualStrings("ccc", "aaa bbb ccc"[br.next..]);
}

test "a line exactly the width of the box already wraps" {
    const gpa = testing.allocator;
    var f = try measureOnlyFont(gpa);
    defer f.table.deinit(gpa);

    // The engine's test is `width <= measured`, so 80px of text does not fit an 80px box.
    try testing.expectEqual(@as(usize, 8), f.breakLine("aaaaaaaa", 90).take);
    try testing.expectEqual(@as(usize, 7), f.breakLine("aaaaaaaa", 80).take);
}

test "a word wider than the box is cut, not overhung" {
    const gpa = testing.allocator;
    var f = try measureOnlyFont(gpa);
    defer f.table.deinit(gpa);

    // No space to fall back to, so the break is mid-word at the last character that fit, and the
    // remainder starts at the character that did not.
    const br = f.breakLine("aaaaaaaaaa bb", 50);
    try testing.expectEqualStrings("aaaa", "aaaaaaaaaa bb"[0..br.take]);
    try testing.expectEqualStrings("aaaaaa bb", "aaaaaaaaaa bb"[br.next..]);
}

test "one character always goes out, however narrow the box" {
    const gpa = testing.allocator;
    var f = try measureOnlyFont(gpa);
    defer f.table.deinit(gpa);

    // A zero-length line is what the engine produces here, and it then recurses on the same string
    // forever. Taking a character costs an overhang and terminates.
    try testing.expectEqual(@as(usize, 1), f.breakLine("abc", 5).take);
    try testing.expectEqual(@as(usize, 1), f.breakLine("abc", 5).next);
}

test "the space a break lands on starts no line" {
    const gpa = testing.allocator;
    var f = try measureOnlyFont(gpa);
    defer f.table.deinit(gpa);

    // The break lands on the LAST space passed, so the spaces that fit stay on the first line —
    // where they draw nothing — and `SetText` trims the rest off the front of the second.
    const br = f.breakLine("aa    bb", 50);
    try testing.expectEqualStrings("aa  ", "aa    bb"[0..br.take]);
    try testing.expectEqualStrings("bb", "aa    bb"[br.next..]);
}

test "how many lines a message takes" {
    const gpa = testing.allocator;
    var f = try measureOnlyFont(gpa);
    defer f.table.deinit(gpa);

    try testing.expectEqual(@as(usize, 1), f.wrappedLines("aaa", 80));
    try testing.expectEqual(@as(usize, 2), f.wrappedLines("aaa bbb ccc", 80));
    try testing.expectEqual(@as(usize, 3), f.wrappedLines("aaa bbb ccc ddd eee", 80));
    // Nothing to say still occupies the row the game gives it.
    try testing.expectEqual(@as(usize, 1), f.wrappedLines("", 80));
}

test "bytes that are not a font table are refused" {
    const gpa = testing.allocator;
    var raw: [header_len]u8 = @splat(0);
    try testing.expectError(Error.BadFontTable, parseTable(gpa, &raw));
}

test "a table that promises more glyphs than it holds is refused" {
    const gpa = testing.allocator;
    var raw: [header_len]u8 = @splat(0);
    @memcpy(raw[0..4], signature);
    std.mem.writeInt(u16, raw[8..10], 4, .little);
    try testing.expectError(Error.ShortFontTable, parseTable(gpa, &raw));
}
