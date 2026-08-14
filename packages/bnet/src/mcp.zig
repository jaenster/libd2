//! MCP — the realm protocol: what a client says once BNCS has logged it in and handed it a
//! realm ticket. Listing and creating characters, then creating or joining a game and being
//! told which game server to dial.
//!
//! This is the vocabulary both ends need to agree on, and it was defined twice: once in a
//! client and once in a realm server, each with its own copy of the opcodes and its own copy
//! of the result codes. They agreed, which is the dangerous kind of duplication — nothing fails
//! until somebody adds a case to one side.
//!
//! No sockets here, and no session. The ORDER those messages go in is a property of the
//! session, and it is not free-form: STARTUP, then CHARLIST2, then CHARLOGON, with no MOTD in
//! between. A second implementation of that order is a bug waiting to be reintroduced, so it is
//! written down at `logon_order` rather than left as a comment in whoever drives the socket.
//!
//! Result codes carry the client's string id where it is known, because that is the thing a
//! player actually sees and the only way to be sure a code means what it is named.

const std = @import("std");

/// MCP message ids. One space, used in both directions: the reply to a request carries the
/// same id as the request.
pub const Op = enum(u8) {
    startup = 0x01,
    charcreate = 0x02,
    creategame = 0x03,
    joingame = 0x04,
    gamelist = 0x05,
    gameinfo = 0x06,
    charlogon = 0x07,
    chardelete = 0x0a,
    ladderdata = 0x11,
    motd = 0x12,
    cancelcreate = 0x13,
    charrank = 0x16,
    charupgrade = 0x18,
    charlist2 = 0x19,
    _,
};

/// The order a client must follow after BNCS hands it a realm ticket. Departing from it hangs
/// the client rather than failing it: MCP_STARTUP has to be dispatched AND answered, and a MOTD
/// squeezed between STARTUP and CHARLIST2 leaves the character list never arriving.
pub const logon_order = [_]Op{ .startup, .charlist2, .charlogon };

/// Answer to MCP_CREATEGAME. The named values are the ones a 1.14d client turns into a specific
/// message; anything else lands on "Error Creating Game" (string 0x1415).
pub const CreateResult = enum(u32) {
    /// The game exists; the client is expected to send JOINGAME next.
    created = 0x00,
    invalid_name = 0x1e, // string 0x1411 "Invalid Game Name"
    already_exists = 0x1f, // string 0x1412 "A Game Already Exists With That Name"
    /// The realm has no game server able to take it. Distinct from the generic error on
    /// purpose: a busy fleet and a broken one should not read the same to a player.
    servers_down = 0x20, // string 0x1413 "Server Down"
    generic = 0x21, // > 0x20 -> string 0x1415 "Error Creating Game"
    dead_hardcore = 0x6e,
    _,

    pub fn describe(self: CreateResult) []const u8 {
        return switch (self) {
            .created => "created (now send JOINGAME)",
            .invalid_name => "invalid game name",
            .already_exists => "game already exists",
            .servers_down => "game servers are down",
            .generic => "error creating game",
            .dead_hardcore => "a dead hardcore character cannot create games",
            _ => "failed (unknown / no game server available)",
        };
    }

    /// Named `succeeded` rather than `ok` because JoinResult's success VALUE is `ok`, and a
    /// field and a method cannot share a name — better both read the same than one of each.
    pub fn succeeded(self: CreateResult) bool {
        return self == .created;
    }
};

/// Answer to MCP_JOINGAME.
pub const JoinResult = enum(u32) {
    ok = 0x00,
    password_incorrect = 0x29, // string 0x1428 "Game name and password don't match."
    no_such_game = 0x2a, // string 0x1427 "Game does not exist."
    game_full = 0x2b, // string 0x1429 "Game is Full."
    level_requirement = 0x2c,
    dead_hardcore = 0x6f,
    /// Hardcore and softcore characters may not share a game.
    hardcore_mix = 0x71, // string 0x1426
    /// The difficulty gates. The realm decides these, so a client never sends them and every
    /// client-side implementation of this enum was missing them.
    need_nightmare = 0x73, // string 0x14f4 / 0x5522 "must kill Diablo/Baal to play Nightmare"
    need_hell = 0x74, // string 0x14f3 / 0x5521 "...in Nightmare to play Hell"
    classic_into_expansion = 0x78, // string 0x2775
    expansion_into_classic = 0x79, // string 0x2776
    /// A ladder character into a non-ladder game or the reverse; the client picks which of
    /// string 0x2ab1 / 0x2ab2 to show from its own ladder flag.
    ladder_mismatch = 0x7d,
    _,

    pub fn describe(self: JoinResult) []const u8 {
        return switch (self) {
            .ok => "OK",
            .password_incorrect => "password incorrect",
            .no_such_game => "game does not exist",
            .game_full => "game is full",
            .level_requirement => "you do not meet the level requirement",
            .dead_hardcore => "a dead hardcore character cannot join",
            .hardcore_mix => "hardcore and softcore may not share a game",
            .classic_into_expansion => "a classic character cannot join an expansion game",
            .expansion_into_classic => "an expansion character cannot join a classic game",
            .need_nightmare => "Diablo must be beaten on Normal to play Nightmare",
            .need_hell => "Baal must be beaten on Nightmare to play Hell",
            .ladder_mismatch => "ladder and non-ladder may not share a game",
            _ => "failed (unknown)",
        };
    }

    pub fn succeeded(self: JoinResult) bool {
        return self == .ok;
    }
};

pub const Difficulty = enum(u32) { normal = 0, nightmare = 1, hell = 2 };

/// What a client asks for when it creates a game. `description` is what shows in the game list.
pub const GameOptions = struct {
    name: []const u8,
    password: []const u8 = "",
    description: []const u8 = "d",
    difficulty: Difficulty = .normal,
    /// The engine's ceiling is eight and it does not negotiate.
    max_players: u8 = 8,
};

/// The MCP frame: a little-endian length that COUNTS ITSELF and the id, then the id, then the
/// body. A server that writes the body length instead leaves the client waiting for three more
/// bytes that never come.
pub const Header = struct {
    pub const len: usize = 3;

    pub fn encode(op: Op, body_len: usize, buf: []u8) error{NoSpace}![]u8 {
        const total = len + body_len;
        if (buf.len < len or total > std.math.maxInt(u16)) return error.NoSpace;
        std.mem.writeInt(u16, buf[0..2], @intCast(total), .little);
        buf[2] = @intFromEnum(op);
        return buf[0..len];
    }

    /// Total frame length and its op, from the first three bytes.
    pub fn decode(buf: []const u8) error{Short}!struct { total: u16, op: Op } {
        if (buf.len < len) return error.Short;
        return .{
            .total = std.mem.readInt(u16, buf[0..2], .little),
            .op = @enumFromInt(buf[2]),
        };
    }
};

const testing = std.testing;

test "the create codes a client renders specifically" {
    // 0x20 and 0x21 are one apart and mean different things to a player: "Server Down" against
    // "Error Creating Game". A realm that returns the generic code for a full fleet tells
    // everyone it is broken.
    try testing.expectEqualStrings("game servers are down", CreateResult.servers_down.describe());
    try testing.expectEqualStrings("error creating game", CreateResult.generic.describe());
    try testing.expect(CreateResult.created.succeeded());
    try testing.expect(!CreateResult.servers_down.succeeded());
    // An unnamed code still describes rather than crashing — the client turns them all into
    // the generic string anyway.
    try testing.expectEqualStrings(
        "failed (unknown / no game server available)",
        (@as(CreateResult, @enumFromInt(0x99))).describe(),
    );
}

test "the join codes, including the three the realm decides" {
    try testing.expectEqual(@as(u32, 0x2a), @intFromEnum(JoinResult.no_such_game));
    try testing.expectEqual(@as(u32, 0x2b), @intFromEnum(JoinResult.game_full));
    try testing.expectEqual(@as(u32, 0x71), @intFromEnum(JoinResult.hardcore_mix));
    // The gates the REALM decides and a client never sends, so every client-side copy of this
    // enum lacked them until the server's copy was folded in here.
    try testing.expectEqual(@as(u32, 0x73), @intFromEnum(JoinResult.need_nightmare));
    try testing.expectEqual(@as(u32, 0x74), @intFromEnum(JoinResult.need_hell));
    try testing.expectEqual(@as(u32, 0x7d), @intFromEnum(JoinResult.ladder_mismatch));
    try testing.expect(JoinResult.ok.succeeded());
    try testing.expectEqualStrings("game is full", JoinResult.game_full.describe());
}

test "the logon order is startup, charlist2, charlogon" {
    try testing.expectEqual(@as(usize, 3), logon_order.len);
    try testing.expectEqual(Op.startup, logon_order[0]);
    try testing.expectEqual(Op.charlist2, logon_order[1]);
    try testing.expectEqual(Op.charlogon, logon_order[2]);
    try testing.expectEqual(@as(u8, 0x19), @intFromEnum(Op.charlist2));
    // MOTD has an id of its own and is still not part of the order: sending it between STARTUP
    // and CHARLIST2 is exactly the mistake this list exists to prevent.
    try testing.expectEqual(@as(u8, 0x12), @intFromEnum(Op.motd));
    for (logon_order) |op| try testing.expect(op != .motd);
}

test "the frame length counts itself" {
    var buf: [3]u8 = undefined;
    const h = try Header.encode(.charlogon, 17, &buf);
    try testing.expectEqual(@as(u16, 20), std.mem.readInt(u16, h[0..2], .little));
    const got = try Header.decode(h);
    try testing.expectEqual(@as(u16, 20), got.total);
    try testing.expectEqual(Op.charlogon, got.op);
    try testing.expectError(error.Short, Header.decode(h[0..2]));
}
