//! Does generating acts over and over, with several held live at once, leak or corrupt anything?
//!
//! That is the drlg-server / wasm-reactor shape rather than the one-shot shape the other gates
//! cover: a worker keeps a handful of generated acts resident (one per session) and churns through
//! many more, on one long-lived `Ctx`. Two things can go wrong there and nowhere else.
//!
//! **Leaks.** `memcheck` watches process RSS, which cannot distinguish a leak from an allocator
//! keeping freed pages, and the wasm heap never returns memory at all. Here every allocation goes
//! through a leak-DETECTING allocator, so a single surviving byte fails the test by count.
//!
//! **Cross-generation corruption.** A generation resets shared state that is deliberately global —
//! the DRLG pool allocator and its live-payload registry, the LvlSub `pDrlgFile` cache, the DS1
//! parse cache (see `lib.beginGeneration`). A handle is supposed to own copies of everything it
//! reports, so a later generation must not be able to touch it. Nothing else checks that: every
//! other gate frees each act before generating the next. This pins one handle for the whole run and
//! re-reads it at the end, then proves the bytes are RIGHT rather than merely unchanged by diffing
//! them against a fresh generation of the same seed.
//!
//! What this canNOT see, by design: the process-lifetime caches (the DS1 record store, the DT1
//! subtile-flag blob, the preset resolver tables, the per-thread composite and inflate scratch) come
//! from `d2-core`'s shared heap rather than a caller's allocator, precisely so a leak-checked caller
//! does not see them as leaks. They are one-time and bounded — measured at 3.4 MB, reached on the
//! first generation and flat over the next hundred — and `d2drlg_heap_usage` is what reports them.

const std = @import("std");
const lib = @import("lib.zig");
const testalloc = @import("testalloc.zig");

/// Handles held simultaneously, and total generate/free cycles.
const live_handles = 20;
const cycles = 100;

const Handle = struct {
    arena: std.heap.ArenaAllocator,
    result: lib.ActFullResult,

    /// Mirrors the C ABI's `d2drlg_gen_act`: a per-act arena for everything the handle reports,
    /// torn down wholesale, with the generation core allocating from `ctx.gpa`.
    fn generate(ctx: *lib.Ctx, gpa: std.mem.Allocator, act_no: i32, seed: u32) !Handle {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const result = try lib.generateActFull(ctx, arena.allocator(), act_no, seed, .nightmare, .{ .walk = true });
        return .{ .arena = arena, .result = result };
    }

    fn deinit(self: *Handle) void {
        self.arena.deinit();
    }

    /// Digest of everything the handle reports, so one flipped cell in any level fails.
    ///
    /// FIELD BY FIELD, never `std.mem.sliceAsBytes` over the structs: struct padding is undefined,
    /// so hashing raw bytes reports two identical lists as different and looks exactly like a
    /// nondeterministic generator. (It cost an hour here before `@sizeOf` gave it away.)
    fn fingerprint(self: *const Handle) u64 {
        var h = std.hash.Wyhash.init(0);
        const int = struct {
            fn add(w: *std.hash.Wyhash, v: anytype) void {
                w.update(std.mem.asBytes(&@as(i64, @intCast(@as(i32, switch (@typeInfo(@TypeOf(v))) {
                    .@"enum" => @intFromEnum(v),
                    else => v,
                })))));
            }
        }.add;
        for (self.result.levels) |l| {
            int(&h, l.meta.level_id);
            int(&h, l.coll_w);
            int(&h, l.coll_h);
            h.update(l.coll_deflated);
            h.update(l.walk_deflated);
            for (l.meta.rooms) |r| {
                inline for (.{ r.x, r.y, r.w, r.h, r.n_type, r.n_preset_type, r.picked_file }) |v| int(&h, v);
            }
            for (l.presets) |u| inline for (.{ u.etype, u.txt_file_no, u.x, u.y }) |v| int(&h, v);
            for (l.adjacents) |adj| {
                int(&h, adj.dest_level_id);
                int(&h, adj.x);
                int(&h, adj.y);
                int(&h, adj.kind);
            }
        }
        return h.final();
    }
};

test "churning 100 act generations with 20 held live leaks nothing and corrupts no handle" {
    var mem: testalloc.Checked = .{};
    defer mem.deinit(); // fails the test on any surviving allocation
    const gpa = mem.allocator();

    var ctx = try lib.Ctx.init(gpa);
    defer ctx.deinit();

    const seed: u32 = 0x12345678;

    // Generated first, freed last, never touched in between.
    var pinned = try Handle.generate(&ctx, gpa, 0, seed);
    defer pinned.deinit();
    const pinned_before = pinned.fingerprint();

    var ring: [live_handles]?Handle = @splat(null);
    var i: usize = 0;
    while (i < cycles) : (i += 1) {
        const slot = i % live_handles;
        if (ring[slot]) |*old| old.deinit(); // the oldest of the live set
        ring[slot] = try Handle.generate(&ctx, gpa, @intCast(i % 5), seed +% @as(u32, @intCast(i)));
        // Read something off every live handle each cycle, so a handle that HAD been corrupted
        // would be touched rather than sitting untouched until the end.
        for (ring) |maybe| if (maybe) |h| try std.testing.expect(h.result.levels.len > 0);
    }
    for (&ring) |*maybe| if (maybe.*) |*h| {
        h.deinit();
        maybe.* = null;
    };

    // Unchanged after 100 interleaved generations...
    try std.testing.expectEqual(pinned_before, pinned.fingerprint());
    // ...and unchanged is only meaningful if it is also CORRECT.
    var fresh = try Handle.generate(&ctx, gpa, 0, seed);
    defer fresh.deinit();
    try std.testing.expectEqual(pinned_before, fresh.fingerprint());
}
