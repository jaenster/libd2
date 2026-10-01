//! The player's items of a save, described: grid cell, graphic, names and the tooltip lines. A thin join
//! of the item list walker (sections.zig) and the text formatter (d2-item `itemtext`).

const std = @import("std");
const item = @import("d2-item");
const sections = @import("sections.zig");

pub const itemtext = item.itemtext;
pub const ItemView = itemtext.ItemView;

/// Every item of the player's list as views, socketed items attached to their host. Per-level stats are
/// evaluated at the character's level unless `opts.char_level` is set by the caller.
pub fn describePlayerItems(d: *const itemtext.Describer, arena: std.mem.Allocator, s: sections.Save, opts: ?itemtext.Options) ![]ItemView {
    var list: std.ArrayListUnmanaged(item.wire.Item) = .empty;
    var it = s.items.iterator();
    while (it.next()) |w| try list.append(arena, w);
    var o = opts orelse itemtext.Options{};
    if (opts == null) {
        const lvl = s.attributes.attributes().level;
        if (lvl > 0 and lvl < 256) o.char_level = @intCast(lvl);
    }
    return d.describeList(arena, list.items, o);
}
