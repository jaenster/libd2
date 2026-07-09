//! objects.txt AutoMap lookup: DS1 preset objects (kind=2) carry an `id` that is
//! the objects.txt row index (D2's GetObjectText(index)); the row's AutoMap column
//! is the automap DC6 cel drawn for that object (Shrine=310, waypoint stones=314,
//! Inifuss=313, ...). This is exactly Charon MapReveal DrawPresets/GenerateOwnCell.
//! We render those cels as marker cells, so shrines/waypoints/quest objects show on
//! the reconstructed automap the same way the maphack draws them.

const std = @import("std");
const txt = @import("txt.zig");

/// One object row's collision footprint: HasCollision0 (mode 0 = the room-init /
/// neutral state) plus SizeX/SizeY (collision extent in SUBTILES). Objects with
/// HasCollision0==0 (shrines that only block on interact, décor, etc.) never block.
pub const Coll = struct { has: bool, sx: i32, sy: i32 };

/// One object row's dynamic-light emitter. Faithful to 1.14d
/// OBJECT_SetLightRGB (@0x4bc580) -> AllocLightMap (@0x474160): the light
/// COLOR is Objects.txt Red/Green/Blue verbatim; the light DIAMETER is the
/// per-mode `Lit` column, and the engine sets radius = (Lit>>1) subtiles,
/// clamped to a max diameter of 0x12 (=> max radius 18 subtiles). We take the
/// brightest lit mode (max Lit0..7) as the object's "when lit" emit value; a
/// row with all Lit==0 does not emit (`radius`==0).
pub const Light = struct { r: u8, g: u8, b: u8, radius: i32 };

pub const Table = struct {
    /// cel[objectRowIndex] = AutoMap value (0 = no marker).
    cel: []i32,
    coll: []Coll,
    /// light[objectRowIndex] = dynamic-light emitter (radius==0 => none).
    light: []Light,
    /// operate[objectRowIndex] = OperateFn — the index into the server's
    /// OBJECTSOPERATEFN dispatch table (@0x732d18, 0x65 entries) InteractWithObject
    /// (@0x584420) calls on interact. Data-observed families: 1 casket/sarcophagus,
    /// 2 shrine, 3 urn/basket, 4 chest, 8 door, 14 corpse, 22 well.
    operate: []i32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Table) void {
        self.allocator.free(self.cel);
        self.allocator.free(self.coll);
        self.allocator.free(self.light);
        self.allocator.free(self.operate);
    }

    /// OperateFn for an objects.txt row (0 = not operable / id out of range).
    pub fn operateFn(self: *const Table, id: i32) i32 {
        if (id < 0 or id >= self.operate.len) return 0;
        return self.operate[@intCast(id)];
    }

    /// Dynamic-light emitter for an objects.txt row, or null if the row emits
    /// no light (all Lit modes zero) or the id is out of range.
    pub fn emitter(self: *const Table, id: i32) ?Light {
        if (id < 0 or id >= self.light.len) return null;
        const l = self.light[@intCast(id)];
        return if (l.radius > 0) l else null;
    }

    /// AutoMap cel for a DS1 object id (row index), or -1 when the object has no
    /// automap marker / id is out of range.
    pub fn lookup(self: *const Table, id: i32) i32 {
        if (id < 0 or id >= self.cel.len) return -1;
        const c = self.cel[@intCast(id)];
        return if (c > 0) c else -1;
    }

    /// Collision footprint for an objects.txt row, or null if the object has no
    /// room-init collision (HasCollision0==0) or the id is out of range.
    pub fn collision(self: *const Table, id: i32) ?Coll {
        if (id < 0 or id >= self.coll.len) return null;
        const c = self.coll[@intCast(id)];
        if (!c.has or c.sx <= 0 or c.sy <= 0) return null;
        return c;
    }
};

pub fn load(gpa: std.mem.Allocator) !Table {
    var t = try txt.Table.parse(gpa, @embedFile("excel/Objects.txt"));
    defer t.deinit();
    const n = t.rowCount();
    const cel = try gpa.alloc(i32, n);
    errdefer gpa.free(cel);
    const coll = try gpa.alloc(Coll, n);
    errdefer gpa.free(coll);
    const light = try gpa.alloc(Light, n);
    errdefer gpa.free(light);
    const operate = try gpa.alloc(i32, n);
    errdefer gpa.free(operate);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        cel[i] = @intCast(t.int(i, "AutoMap"));
        coll[i] = .{ .has = t.int(i, "HasCollision0") != 0, .sx = @intCast(t.int(i, "SizeX")), .sy = @intCast(t.int(i, "SizeY")) };
        operate[i] = @intCast(t.int(i, "OperateFn"));
        // Brightest lit mode -> emit diameter; engine radius = (Lit>>1) clamped
        // to 18 subtiles. Color is Red/Green/Blue verbatim.
        var max_lit: i64 = 0;
        inline for (.{ "Lit0", "Lit1", "Lit2", "Lit3", "Lit4", "Lit5", "Lit6", "Lit7" }) |col| {
            const v = t.int(i, col);
            if (v > max_lit) max_lit = v;
        }
        const radius: i32 = @intCast(@min(@divTrunc(max_lit, 2), 18));
        light[i] = .{
            .r = @intCast(std.math.clamp(t.int(i, "Red"), 0, 255)),
            .g = @intCast(std.math.clamp(t.int(i, "Green"), 0, 255)),
            .b = @intCast(std.math.clamp(t.int(i, "Blue"), 0, 255)),
            .radius = radius,
        };
    }
    return .{ .cel = cel, .coll = coll, .light = light, .operate = operate, .allocator = gpa };
}

const testing = std.testing;

test "objects table maps shrine/stone ids to automap cels" {
    var tbl = try load(testing.allocator);
    defer tbl.deinit();
    // Shrine (id 2) -> 310, waypoint stones (id 17..22) -> 314, Inifuss (id 30) -> 313.
    try testing.expectEqual(@as(i32, 310), tbl.lookup(2));
    try testing.expectEqual(@as(i32, 314), tbl.lookup(17));
    try testing.expectEqual(@as(i32, 313), tbl.lookup(30));
    // A non-marker object (id 0 = well/none) -> -1.
    try testing.expectEqual(@as(i32, -1), tbl.lookup(0));
    // Count objects that carry a marker — should be the 64 we saw in objects.txt.
    var markers: usize = 0;
    for (tbl.cel) |c| if (c > 0) {
        markers += 1;
    };
    try testing.expect(markers >= 60);
}
