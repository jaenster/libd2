const std = @import("std");
const ds1 = @import("d2-formats").ds1;
const render = @import("render.zig");
const automap = @import("automap.zig");
const d2drlg = @import("d2-drlg");
const preset = d2drlg.gen.preset;
const s = d2drlg.gen.abi;

pub fn main(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.page_allocator;

    var args = std.process.Args.Iterator.init(init.args);
    _ = args.next();
    const cmd = args.next() orelse "help";

    if (std.mem.eql(u8, cmd, "ds1")) {
        const path = args.next() orelse {
            std.debug.print("usage: d2-render ds1 <file.ds1>\n", .{});
            return;
        };
        var threaded = std.Io.Threaded.init_single_threaded;
        const io = threaded.io();
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024 * 1024));
        defer gpa.free(bytes);
        var d = try ds1.parse(gpa, bytes);
        defer d.deinit();
        std.debug.print("{s}: v{d} {d}x{d} act={d} walls={d} floors={d} objs={d}\n", .{
            path, d.version, d.width, d.height, d.act, d.wall_layers.len, d.floor_layers.len, d.objects.len,
        });
        const map = try render.asciiMap(&d, gpa);
        defer gpa.free(map);
        std.debug.print("{s}", .{map});
        return;
    }

    if (std.mem.eql(u8, cmd, "amdiag")) {
        const level_id = std.fmt.parseInt(i32, args.next() orelse "34", 10) catch 34;
        const seed = std.fmt.parseInt(u32, args.next() orelse "0x1234abcd", 0) catch 0x1234abcd;
        var ctx = try d2drlg.Ctx.init(gpa);
        defer ctx.deinit();
        var amt = try automap.AutomapTable.load(gpa);
        defer amt.deinit();
        const tlv = ctx.act.level(level_id).?;
        const lt: i32 = @intCast(tlv.lvl_type);
        var w: i32 = 64;
        var h: i32 = 64;
        if (tlv.size_x > 0 and tlv.size_y > 0) {
            w = @intCast(tlv.size_x);
            h = @intCast(tlv.size_y);
        }
        const lvl = try d2drlg.generate(&ctx, seed, @enumFromInt(level_id), .normal, .{ .x = 0, .y = 0, .w = w, .h = h });
        defer lvl.deinit();
        var fhit: usize = 0;
        var fmiss: usize = 0;
        var whit: usize = 0;
        var wmiss: usize = 0;
        var wmisses = std.AutoHashMapUnmanaged(u64, u32).empty;
        defer wmisses.deinit(gpa);
        var pr = lvl.firstRoom();
        while (pr) |p| : (pr = p.pRoomExNext) {
            const data = p.pRoomExData orelse continue;
            const rd: *s.D2DrlgPresetRoomStrc = @ptrCast(@alignCast(data));
            const pmap = rd.pMap orelse continue;
            if (pmap.pTxtLevelPrest == null) continue;
            var d = preset.unpackDs1(gpa, preset.presetDs1Path(pmap) orelse continue) orelse continue;
            defer d.deinit();
            for (d.floor_layers) |fl| for (fl) |c| {
                if (c.raw & 0x00ff_ffff == 0) continue;
                const mn: i32 = @intCast((c.raw >> 20) & 0x3f);
                const sub: i32 = @intCast((c.raw >> 8) & 0xff);
                if (amt.lookup(lt, 0, mn, sub, 0) >= 0) fhit += 1 else fmiss += 1;
            };
            for (d.wall_layers) |wl| {
                const n = @min(wl.wall.len, wl.orient.len);
                var i: usize = 0;
                while (i < n) : (i += 1) {
                    if (wl.wall[i].raw & 0x00ff_ffff == 0) continue;
                    const orient: i32 = wl.orient[i].prop1;
                    const mn: i32 = @intCast((wl.wall[i].raw >> 20) & 0x3f);
                    const sub: i32 = @intCast((wl.wall[i].raw >> 8) & 0xff);
                    if (amt.lookup(lt, orient, mn, sub, 0) >= 0) whit += 1 else {
                        wmiss += 1;
                        const k = (@as(u64, @intCast(orient & 0xff)) << 32) | (@as(u64, @intCast(mn & 0xffff)) << 16) | @as(u64, @intCast(sub & 0xffff));
                        const e = wmisses.getOrPutValue(gpa, k, 0) catch continue;
                        e.value_ptr.* += 1;
                    }
                }
            }
        }
        std.debug.print("level {d} \"{s}\" LevelType={d}: floor hit={d} miss={d} | wall hit={d} miss={d}\n", .{ level_id, tlv.name, lt, fhit, fmiss, whit, wmiss });
        std.debug.print("top missing WALL (orient/main/sub -> count):\n", .{});
        var it = wmisses.iterator();
        var shown: usize = 0;
        while (it.next()) |e| {
            if (shown >= 15) break;
            const k = e.key_ptr.*;
            std.debug.print("  o={d} m={d} s={d}  x{d}\n", .{ (k >> 32) & 0xff, (k >> 16) & 0xffff, k & 0xffff, e.value_ptr.* });
            shown += 1;
        }
        return;
    }

    std.debug.print(
        \\d2-render — D2 1.14d automap + DT1 tile-art render layer (Zig)
        \\usage:
        \\  d2-render ds1 <file.ds1>       parse + ASCII-render a DS1 map
        \\  d2-render amdiag <lvl> <seed>  automap.txt tile-coverage diagnostic
        \\
    , .{});
}
