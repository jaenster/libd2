//! The realm session: everything between "I have an account" and "I have a game to dial".
//!
//! BNCS gets you authenticated and tells you which realms exist. The realm hands off to MCP, which
//! owns characters and games. Only at the very end does it name a game server, a token and a hash —
//! and that triple is the whole point: it is what the in-game protocol needs to enter a game.
//!
//! The order matters and is not negotiable: the real 1.14d client sends STARTUP -> CHARLIST2 ->
//! CHARLOGON with no MOTD in between, and real Battle.net's MCP goes silent if you insert one.
//!
//! Generic over its transport so this file stays what the rest of the package is — no libc, no
//! allocator, no std.io. A caller supplies a type with five declarations and gets a session:
//!
//! ```zig
//! const Stream = ...;                                 // whatever a connection is
//! fn connect(host: []const u8, port: u16) !Stream;
//! fn read(s: Stream, buf: []u8) !usize;               // 0 means the peer closed
//! fn writeAll(s: Stream, bytes: []const u8) !void;
//! fn close(s: Stream) void;
//! ```
//!
//! That is a POSIX socket on a server, Winsock in a Windows launcher, and a replayed capture in a
//! test — and none of those belong in a protocol library.

const std = @import("std");
const xsha1 = @import("xsha1.zig");
const cdkey = @import("cdkey.zig");
const checkrev = @import("checkrev.zig");
const mcp = @import("mcp.zig");

const SID_AUTH_INFO = 0x50;
const SID_AUTH_CHECK = 0x51;
const SID_PING = 0x25;
const SID_LOGONRESPONSE2 = 0x3a;
const SID_CREATEACCOUNT2 = 0x3d;
const SID_LOGONREALMEX = 0x3e;
const SID_QUERYREALMS2 = 0x40;

const MCP_STARTUP = @intFromEnum(mcp.Op.startup);
const MCP_CHARCREATE = @intFromEnum(mcp.Op.charcreate);
const MCP_CHARDELETE = @intFromEnum(mcp.Op.chardelete);
const MCP_CREATEGAME = @intFromEnum(mcp.Op.creategame);
const MCP_JOINGAME = @intFromEnum(mcp.Op.joingame);
const MCP_CHARLOGON = @intFromEnum(mcp.Op.charlogon);
const MCP_CHARLIST2 = @intFromEnum(mcp.Op.charlist2);

const CLIENT_TOKEN: u32 = 0xCAFEBABE;

/// The version-check MPQ whose algorithm `checkrev` implements. Any other name means a different
/// hashing routine, so our answer would be wrong — better to say so than to send it.
const EXPECTED_MPQ = "CheckRevision.mpq";

pub const Error = error{
    ShortReply,
    BadFrame,
    Closed,
    VersionRejected,
    UnexpectedCheckRevisionMPQ,
    BadKey,
    LoginFailed,
    NoRealms,
    RealmLogonFailed,
    RealmUnreachable,
    RealmRejected,
    NoSuchCharacter,
    CharacterRejected,
    CharLogonFailed,
    JoinFailed,
    NotInRealm,
};

pub const Options = struct {
    host: []const u8,
    port: u16 = 6112,
    /// D2DV (classic) or D2XP (expansion).
    product: []const u8 = "D2XP",
    game_version: []const u8 = "1.14.3.71",
    /// Comma-separated 26-char CD-keys. A permissive realm needs none.
    keys: ?[]const u8 = null,
    sig_ok: u8 = 1,
    /// Answer the version check even when the server names an MPQ we do not implement.
    force_checkrev: bool = false,
    /// Closed-realm password. Every 1.14d client sends the same literal.
    realm_password: []const u8 = "password",
    /// Where the narration goes. Null is silent, which is what a GUI or a daemon wants; a CLI
    /// passes something that prints. The callback owns nothing — the slice dies on return.
    log: ?*const fn (msg: []const u8) void = null,
};

/// A character as the realm describes it, which is all we know before entering a game.
pub const Character = struct {
    name_buf: [24]u8 = @splat(0),
    name_len: usize = 0,
    /// nCharClass, as CharStats.txt orders them. GAMELOGON carries it, and getting it wrong gives
    /// the game server a character whose skills and animations do not match its save.
    class: u8 = 0,
    level: u8 = 1,
    expansion: bool = true,
    hardcore: bool = false,
    dead: bool = false,
    ladder: bool = false,
    /// How far it has got, which is what the character list draws as a title.
    progression: u8 = 0,

    pub fn name(self: *const Character) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    fn setName(self: *Character, from: []const u8) void {
        const keep = @min(from.len, self.name_buf.len);
        @memcpy(self.name_buf[0..keep], from[0..keep]);
        self.name_len = keep;
    }
};

/// What JOINGAME hands back: where the game lives and how to prove we were let in.
pub const Ticket = struct {
    gs_ip: [4]u8,
    /// Where to actually dial. Usually `gs_ip` written out, but a realm that was never told its
    /// own public address answers 0.0.0.0, and then it is the host the realm itself was reached on.
    gs_host_buf: [64]u8 = @splat(0),
    gs_host_len: usize = 0,
    /// nGameToken — resolves the game on the game server.
    token: u16,
    /// nGameHash — proves the realm sent us.
    hash: u32,
    character: Character,

    pub fn gsHost(self: *const Ticket) []const u8 {
        return self.gs_host_buf[0..self.gs_host_len];
    }
};

pub const CreateResult = mcp.CreateResult;
pub const CharCreateResult = mcp.CharCreateResult;
pub const JoinResult = mcp.JoinResult;
pub const Difficulty = mcp.Difficulty;
pub const GameOptions = mcp.GameOptions;

/// MCP_CHARCREATE's status word. 0x20 is the bit that makes a character an expansion one; the
/// hardcore and ladder bits live alongside it and are not offered yet.
const STATUS_EXPANSION: u16 = 0x20;

fn fourcc(s: []const u8) u32 {
    return @as(u32, s[3]) | (@as(u32, s[2]) << 8) | (@as(u32, s[1]) << 16) | (@as(u32, s[0]) << 24);
}

fn cstrAt(b: []const u8, off: usize) []const u8 {
    if (off >= b.len) return "";
    const end = std.mem.indexOfScalarPos(u8, b, off, 0) orelse b.len;
    return b[off..end];
}

fn authMeaning(r: u32) []const u8 {
    return switch (r) {
        0x000 => "PASSED — version + checksum accepted",
        0x100 => "old game version (forced patch)",
        0x101 => "invalid version",
        0x102 => "game version must be downgraded",
        0x200 => "invalid CD key  => VERSION CHECK PASSED",
        0x201 => "CD key in use   => VERSION CHECK PASSED",
        0x202 => "banned key      => VERSION CHECK PASSED",
        0x203 => "wrong product   => VERSION CHECK PASSED",
        else => if (r & 0xFF00 == 0x0100) "invalid-version variant" else "other (version likely passed)",
    };
}

/// The statstring the char-select screen renders each character from.
///
/// Layout, from CHARSEL_ParseRealmCharList @0x43aab0: [0..2] realm char count, [2..13] the eleven
/// body-component graphics, [13] class+1, [14..25] their colour transforms, [25] level, [26..28]
/// flags, [28..30] unused, [30] act, [31..33] unused, [33..] guild tag.
///
/// Every byte of it travels inside a C string, so none of them may be zero. That is why the class
/// is sent one higher than it is, why "nothing" in a component slot is 0xFF, and — the part that
/// is easy to get wrong — why the multi-byte fields are 14-BIT: seven bits per byte with the high
/// bit forced on. Reading the flags byte raw makes the expansion bit (0x20) look like the hardcore
/// one (0x04) and every character comes back classic.
pub fn readStatString(stat: []const u8, into: *Character) void {
    if (stat.len > 13) into.class = if (stat[13] > 0) stat[13] - 1 else 0;
    if (stat.len > 25) into.level = stat[25];
    if (stat.len > 27) {
        const flags: u16 = (@as(u16, stat[26]) & 0x7f) | ((@as(u16, stat[27]) & 0x7f) << 7);
        // The low byte mirrors the .d2s status byte at 0x24; the high byte is how far the
        // character has got, which is what picks its title.
        into.hardcore = (flags & 0x04) != 0;
        into.dead = (flags & 0x08) != 0;
        into.expansion = (flags & 0x20) != 0;
        into.ladder = (flags & 0x40) != 0;
        into.progression = @intCast((flags >> 8) & 0x1f);
    }
}

/// A realm session over `T`. See the file comment for what `T` has to declare.
pub fn Session(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const Stream = T.Stream;

        opts: Options,
        bncs: Stream,
        mcp: ?Stream = null,
        server_token: u32 = 0,
        character: Character = .{},
        /// Which host we dialled, so a NATed MCP address can fall back to it.
        gateway: []const u8 = "",

        rx: [16384]u8 = undefined,
        rx_len: usize = 0,
        mrx: [16384]u8 = undefined,
        mrx_len: usize = 0,

        fn say(self: *const Self, comptime fmt: []const u8, args: anytype) void {
            const sink = self.opts.log orelse return;
            var buf: [512]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, fmt, args) catch buf[0..buf.len];
            sink(msg);
        }

        // ── BNCS framing: [0xFF][id][u16 len incl header][body] ──

        pub fn send(self: *Self, id: u8, body: []const u8) !void {
            var hdr: [4]u8 = .{ 0xFF, id, 0, 0 };
            std.mem.writeInt(u16, hdr[2..4], @intCast(body.len + 4), .little);
            try T.writeAll(self.bncs, &hdr);
            try T.writeAll(self.bncs, body);
        }

        /// Read frames until one with `want` arrives, echoing SID_PING along the way — the server
        /// pings mid-handshake and a client that ignores it gets dropped.
        pub fn recvUntil(self: *Self, want: u8, out: []u8) ![]const u8 {
            while (true) {
                while (self.rx_len >= 4 and self.rx[0] == 0xFF) {
                    const id = self.rx[1];
                    const plen = std.mem.readInt(u16, self.rx[2..4], .little);
                    if (plen < 4 or plen > self.rx.len) return Error.BadFrame;
                    if (self.rx_len < plen) break;
                    const body = self.rx[4..plen];
                    if (id == SID_PING) {
                        var echo: [8]u8 = .{ 0xFF, SID_PING, 8, 0, 0, 0, 0, 0 };
                        @memcpy(echo[4..8], body[0..4]);
                        try T.writeAll(self.bncs, &echo);
                    } else if (id == want) {
                        const blen = plen - 4;
                        if (blen > out.len) return Error.BadFrame;
                        @memcpy(out[0..blen], body);
                        self.dropBncs(plen);
                        return out[0..blen];
                    }
                    self.dropBncs(plen);
                }
                const got = try T.read(self.bncs, self.rx[self.rx_len..]);
                if (got == 0) return Error.Closed;
                self.rx_len += got;
            }
        }

        fn dropBncs(self: *Self, plen: usize) void {
            std.mem.copyForwards(u8, self.rx[0 .. self.rx_len - plen], self.rx[plen..self.rx_len]);
            self.rx_len -= plen;
        }

        // ── MCP framing: [u16 len incl header][id][body], on its own connection ──

        fn mcpSend(self: *Self, id: u8, body: []const u8) !void {
            const s = self.mcp orelse return Error.NotInRealm;
            var hdr: [3]u8 = undefined;
            std.mem.writeInt(u16, hdr[0..2], @intCast(body.len + 3), .little);
            hdr[2] = id;
            try T.writeAll(s, &hdr);
            if (body.len > 0) try T.writeAll(s, body);
        }

        fn mcpRecv(self: *Self, want: u8, out: []u8) ![]const u8 {
            const s = self.mcp orelse return Error.NotInRealm;
            while (true) {
                while (self.mrx_len >= 3) {
                    const plen = std.mem.readInt(u16, self.mrx[0..2], .little);
                    if (plen < 3 or plen > self.mrx.len) return Error.BadFrame;
                    if (self.mrx_len < plen) break;
                    const id = self.mrx[2];
                    const blen = plen - 3;
                    if (id == want) {
                        if (blen > out.len) return Error.BadFrame;
                        @memcpy(out[0..blen], self.mrx[3..plen]);
                        self.dropMcp(plen);
                        return out[0..blen];
                    }
                    self.dropMcp(plen);
                }
                const got = try T.read(s, self.mrx[self.mrx_len..]);
                if (got == 0) return Error.Closed;
                self.mrx_len += got;
            }
        }

        fn dropMcp(self: *Self, plen: usize) void {
            std.mem.copyForwards(u8, self.mrx[0 .. self.mrx_len - plen], self.mrx[plen..self.mrx_len]);
            self.mrx_len -= plen;
        }

        /// Connect and clear the version gauntlet: AUTH_INFO names the challenge, AUTH_CHECK
        /// answers it. No account is involved yet — this much works against any server, which is
        /// exactly why it is a separate step.
        pub fn connect(opts: Options) !Self {
            const s = try T.connect(opts.host, opts.port);
            errdefer T.close(s);
            var self = Self{ .opts = opts, .bncs = s, .gateway = opts.host };
            try T.writeAll(s, &[_]u8{0x01}); // protocol selector: BNCS

            var body: [128]u8 = undefined;
            var w: usize = 0;
            for ([_]u32{ 0, fourcc("IX86"), fourcc(opts.product), 0x0E, 0, 0, 0, 0, 0 }) |v| {
                std.mem.writeInt(u32, body[w..][0..4], v, .little);
                w += 4;
            }
            for ("USA\x00United States\x00") |c| {
                body[w] = c;
                w += 1;
            }
            try self.send(SID_AUTH_INFO, body[0..w]);

            var aibuf: [4096]u8 = undefined;
            const ai = try self.recvUntil(SID_AUTH_INFO, &aibuf);
            if (ai.len < 20) return Error.ShortReply;
            self.server_token = std.mem.readInt(u32, ai[4..8], .little);
            const mpq = cstrAt(ai, 20);
            const challenge = cstrAt(ai, 20 + mpq.len + 1);
            self.say("[AUTH_INFO] serverToken=0x{x:0>8} mpq=\"{s}\"\n", .{ self.server_token, mpq });

            // Modern bnet sends a base64 challenge; classic realmd/pvpgn sends the legacy
            // "A=1 B=1 C=1 …" formula computed over game files a clientless tool does not ship.
            // Permissive realms accept any AUTH_CHECK, so the classic path sends placeholders.
            var full_buf: [64]u8 = undefined;
            var exe_version: u32 = 0;
            var exe_hash: u32 = undefined;
            var exe_info: []const u8 = undefined;
            if (std.mem.indexOfScalar(u8, challenge, ' ') != null or std.mem.startsWith(u8, challenge, "A=")) {
                exe_version = 0x01000001;
                exe_hash = 0xdeadbeef;
                exe_info = "";
                self.say("[checkrev] classic challenge -> placeholder hash (permissive realm)\n", .{});
            } else {
                if (!std.mem.eql(u8, mpq, EXPECTED_MPQ) and !opts.force_checkrev) {
                    self.say("[checkrev] unexpected MPQ \"{s}\"; not guessing\n", .{mpq});
                    return Error.UnexpectedCheckRevisionMPQ;
                }
                const full = checkrev.response(challenge, opts.game_version, opts.sig_ok, &full_buf) orelse
                    return Error.ShortReply;
                exe_hash = std.mem.readInt(u32, full[0..4], .little);
                exe_info = full[4..];
                self.say("[checkrev] exeHash=0x{x:0>8}\n", .{exe_hash});
            }

            var cb: [512]u8 = undefined;
            var nkeys: u32 = 0;
            std.mem.writeInt(u32, cb[0..4], CLIENT_TOKEN, .little);
            std.mem.writeInt(u32, cb[4..8], exe_version, .little);
            std.mem.writeInt(u32, cb[8..12], exe_hash, .little);
            std.mem.writeInt(u32, cb[16..20], 0, .little); // spawn
            var cw: usize = 20;
            var keyit = std.mem.tokenizeScalar(u8, opts.keys orelse "", ',');
            while (keyit.next()) |k| {
                const blk = cdkey.keyBlock26(k, CLIENT_TOKEN, self.server_token) orelse return Error.BadKey;
                var wire: [36]u8 = undefined;
                blk.writeWire(&wire);
                @memcpy(cb[cw .. cw + 36], &wire);
                cw += 36;
                nkeys += 1;
            }
            std.mem.writeInt(u32, cb[12..16], nkeys, .little);
            @memcpy(cb[cw .. cw + exe_info.len], exe_info);
            cw += exe_info.len;
            cb[cw] = 0;
            cw += 1;
            for ("owner\x00") |c| { // CD-key owner
                cb[cw] = c;
                cw += 1;
            }
            try self.send(SID_AUTH_CHECK, cb[0..cw]);

            var acbuf: [1024]u8 = undefined;
            const ac = try self.recvUntil(SID_AUTH_CHECK, &acbuf);
            if (ac.len < 4) return Error.ShortReply;
            const result = std.mem.readInt(u32, ac[0..4], .little);
            self.say("[AUTH_CHECK] result=0x{x:0>4} => {s}\n", .{ result, authMeaning(result) });
            return self;
        }

        pub fn deinit(self: *Self) void {
            if (self.mcp) |s| T.close(s);
            self.mcp = null;
            T.close(self.bncs);
        }

        /// Register an account. CREATE hashes the password once; LOGON hashes it twice with both
        /// tokens — using the wrong one of the two is a silent "incorrect password".
        pub fn createAccount(self: *Self, account: []const u8, password: []const u8) !bool {
            const pwhash = xsha1.passwordHash(password);
            var nb: [320]u8 = undefined;
            @memcpy(nb[0..20], &pwhash);
            @memcpy(nb[20 .. 20 + account.len], account);
            nb[20 + account.len] = 0;
            try self.send(SID_CREATEACCOUNT2, nb[0 .. 20 + account.len + 1]);
            var nrbuf: [256]u8 = undefined;
            const nr = try self.recvUntil(SID_CREATEACCOUNT2, &nrbuf);
            const st = if (nr.len >= 4) std.mem.readInt(u32, nr[0..4], .little) else 0xffffffff;
            self.say("[CREATEACCOUNT2] \"{s}\" status={d}\n", .{ account, st });
            return st == 0;
        }

        pub fn login(self: *Self, account: []const u8, password: []const u8) !void {
            const inner = xsha1.passwordHash(password);
            const pwhash = xsha1.doubleHash(CLIENT_TOKEN, self.server_token, inner);
            var pb: [320]u8 = undefined;
            std.mem.writeInt(u32, pb[0..4], CLIENT_TOKEN, .little);
            std.mem.writeInt(u32, pb[4..8], self.server_token, .little);
            @memcpy(pb[8..28], &pwhash);
            @memcpy(pb[28 .. 28 + account.len], account);
            pb[28 + account.len] = 0;
            try self.send(SID_LOGONRESPONSE2, pb[0 .. 28 + account.len + 1]);
            var lbuf: [256]u8 = undefined;
            const lr = try self.recvUntil(SID_LOGONRESPONSE2, &lbuf);
            const res = if (lr.len >= 4) std.mem.readInt(u32, lr[0..4], .little) else 0xffffffff;
            self.say("[LOGONRESPONSE2] \"{s}\" result={d}\n", .{ account, res });
            if (res != 0) return Error.LoginFailed;
        }

        /// Log on to a realm and open MCP behind it. `name` picks a realm by title; null takes the
        /// first listed, which is the only one on our own server.
        pub fn enterRealm(self: *Self, name: ?[]const u8) !void {
            // The body must be EMPTY. Real bnet closes the connection on a non-empty QUERYREALMS2.
            try self.send(SID_QUERYREALMS2, &[_]u8{});
            var qbuf: [4096]u8 = undefined;
            const qr = try self.recvUntil(SID_QUERYREALMS2, &qbuf);
            var chosen: []const u8 = "";
            if (qr.len >= 8) {
                const count = std.mem.readInt(u32, qr[4..8], .little);
                var off: usize = 8;
                var n: u32 = 0;
                while (n < count and off + 4 <= qr.len) : (n += 1) {
                    off += 4; // per-realm unknown dword
                    const title = cstrAt(qr, off);
                    off += title.len + 1;
                    const desc = cstrAt(qr, off);
                    off += desc.len + 1;
                    const wanted = if (name) |want| std.ascii.eqlIgnoreCase(want, title) else chosen.len == 0;
                    if (wanted) chosen = title;
                    self.say("[realm] \"{s}\" ({s})\n", .{ title, desc });
                }
            }
            if (chosen.len == 0) return Error.NoRealms;

            const realm_pw = xsha1.doubleHash(CLIENT_TOKEN, self.server_token, xsha1.xsha1(self.opts.realm_password));
            var rb: [128]u8 = undefined;
            std.mem.writeInt(u32, rb[0..4], CLIENT_TOKEN, .little);
            @memcpy(rb[4..24], &realm_pw);
            @memcpy(rb[24 .. 24 + chosen.len], chosen);
            rb[24 + chosen.len] = 0;
            try self.send(SID_LOGONREALMEX, rb[0 .. 24 + chosen.len + 1]);
            var rrbuf: [256]u8 = undefined;
            const rr = try self.recvUntil(SID_LOGONREALMEX, &rrbuf);
            // Real bnet's success layout differs from realmd's, so success is read from the reply
            // LENGTH, not a status dword: ~8 bytes is cookie+status (a failure), while a long
            // reply carries the MCP handoff — cookie, status, chunk1, ip, port, chunk2, name.
            if (rr.len < 30) {
                self.say("[LOGONREALMEX] \"{s}\" failed\n", .{chosen});
                return Error.RealmLogonFailed;
            }

            const ip4 = rr[16..20];
            const mport = std.mem.readInt(u16, rr[20..22], .big);
            var ipstr: [20]u8 = undefined;
            const ipfmt = std.fmt.bufPrint(&ipstr, "{d}.{d}.{d}.{d}", .{ ip4[0], ip4[1], ip4[2], ip4[3] }) catch
                return Error.ShortReply;
            // Real bnet answers with the char server's PRIVATE (NATed) address, unreachable from
            // outside. Falling back to the host we dialled covers the case where the gateway
            // proxies MCP as well, which is what our own realm does.
            const priv = ip4[0] == 10 or (ip4[0] == 192 and ip4[1] == 168) or
                (ip4[0] == 172 and ip4[1] >= 16 and ip4[1] <= 31) or ip4[0] == 127 or ip4[0] == 0;
            const ips = if (priv) self.gateway else ipfmt;
            self.say("[MCP] {s}:{d}\n", .{ ips, mport });

            const ms = T.connect(ips, mport) catch return Error.RealmUnreachable;
            self.mcp = ms;
            self.mrx_len = 0;
            try T.writeAll(ms, &[_]u8{0x01}); // MCP protocol selector

            // STARTUP forwards cookie+status+chunk1(8)+chunk2(48) straight out of the realm reply.
            var sb: [64]u8 = @splat(0);
            @memcpy(sb[0..16], rr[0..16]);
            if (rr.len >= 72) @memcpy(sb[16..64], rr[24..72]);
            try self.mcpSend(MCP_STARTUP, &sb);
            var mb: [8192]u8 = undefined;
            const sr = self.mcpRecv(MCP_STARTUP, &mb) catch return Error.RealmUnreachable;
            const sres = if (sr.len >= 4) std.mem.readInt(u32, sr[0..4], .little) else 0xffffffff;
            self.say("[MCP_STARTUP] result=0x{x}\n", .{sres});
            if (sres != 0) return Error.RealmRejected;
        }

        /// List the account's characters. Also where class and level come from — the realm never
        /// states them outright, they are encoded in the char-select statstring.
        pub fn characters(self: *Self, out: []Character) ![]Character {
            var req: [4]u8 = undefined;
            std.mem.writeInt(u32, &req, 8, .little);
            try self.mcpSend(MCP_CHARLIST2, &req);
            var mb: [8192]u8 = undefined;
            const cl = try self.mcpRecv(MCP_CHARLIST2, &mb);
            if (cl.len < 8) return out[0..0];
            const returned = std.mem.readInt(u16, cl[6..8], .little);
            var off: usize = 8;
            var n: usize = 0;
            while (n < returned and n < out.len and off + 4 < cl.len) : (n += 1) {
                off += 4; // expiry
                const name = cstrAt(cl, off);
                off += name.len + 1;
                const stat = cstrAt(cl, off);
                off += stat.len + 1;
                out[n] = .{};
                out[n].setName(name);
                readStatString(stat, &out[n]);
                self.say("[char] \"{s}\" class={d} level={d}\n", .{ out[n].name(), out[n].class, out[n].level });
            }
            return out[0..n];
        }

        /// Create a character.
        ///
        /// The reply's result word is the whole answer and it is not a boolean: a name already
        /// taken and a name the realm will not accept are different failures and a player has to
        /// be told which. `mcp.CreateResult` names them.
        pub fn createCharacter(self: *Self, name: []const u8, class: u8, expansion: bool) !CharCreateResult {
            if (name.len == 0 or name.len > 15) return Error.CharacterRejected;
            var ccb: [64]u8 = undefined;
            std.mem.writeInt(u32, ccb[0..4], class, .little);
            std.mem.writeInt(u16, ccb[4..6], if (expansion) STATUS_EXPANSION else 0, .little);
            @memcpy(ccb[6 .. 6 + name.len], name);
            ccb[6 + name.len] = 0;
            try self.mcpSend(MCP_CHARCREATE, ccb[0 .. 7 + name.len]);
            var mb: [1024]u8 = undefined;
            const ccr = try self.mcpRecv(MCP_CHARCREATE, &mb);
            const raw = if (ccr.len >= 4) std.mem.readInt(u32, ccr[0..4], .little) else 0xffffffff;
            const res: CharCreateResult = @enumFromInt(raw);
            self.say("[MCP_CHARCREATE] \"{s}\" class={d} => {s}\n", .{ name, class, res.describe() });
            if (res.succeeded()) {
                self.character = .{ .class = class, .expansion = expansion };
                self.character.setName(name);
            }
            return res;
        }

        /// Delete one. The realm answers with a result word of its own; zero is gone.
        pub fn deleteCharacter(self: *Self, name: []const u8) !bool {
            var b: [64]u8 = undefined;
            @memcpy(b[0..name.len], name);
            b[name.len] = 0;
            try self.mcpSend(MCP_CHARDELETE, b[0 .. name.len + 1]);
            var mb: [256]u8 = undefined;
            const r = try self.mcpRecv(MCP_CHARDELETE, &mb);
            const res = if (r.len >= 4) std.mem.readInt(u32, r[0..4], .little) else 0xffffffff;
            self.say("[MCP_CHARDELETE] \"{s}\" result=0x{x}\n", .{ name, res });
            return res == 0;
        }

        /// Log on to a character. This is what makes the realm connection stateful — games are
        /// created BY a character.
        pub fn logonCharacter(self: *Self, who: Character) !void {
            var b: [32]u8 = undefined;
            const n = who.name();
            @memcpy(b[0..n.len], n);
            b[n.len] = 0;
            try self.mcpSend(MCP_CHARLOGON, b[0 .. n.len + 1]);
            var mb: [256]u8 = undefined;
            const r = try self.mcpRecv(MCP_CHARLOGON, &mb);
            const res = if (r.len >= 4) std.mem.readInt(u32, r[0..4], .little) else 0xffffffff;
            self.say("[MCP_CHARLOGON] \"{s}\" result=0x{x}\n", .{ n, res });
            if (res != 0) return Error.CharLogonFailed;
            self.character = who;
        }

        /// Ask the realm to make a game. The reply's result word is at offset 6, behind the
        /// request id and the game token — reading it from the front gets the token instead and
        /// every create looks like it worked.
        pub fn createGame(self: *Self, game: GameOptions) !CreateResult {
            var b: [256]u8 = undefined;
            std.mem.writeInt(u16, b[0..2], 1, .little); // request id
            std.mem.writeInt(u32, b[2..6], @intFromEnum(game.difficulty), .little);
            b[6] = 1; // unknown, always 1
            b[7] = 0; // player difficulty
            b[8] = game.max_players;
            var w: usize = 9;
            for ([_][]const u8{ game.name, game.password, game.description }) |part| {
                @memcpy(b[w..][0..part.len], part);
                w += part.len;
                b[w] = 0;
                w += 1;
            }
            try self.mcpSend(MCP_CREATEGAME, b[0..w]);
            var mb: [1024]u8 = undefined;
            const r = try self.mcpRecv(MCP_CREATEGAME, &mb);
            const res: CreateResult = @enumFromInt(if (r.len >= 10) std.mem.readInt(u32, r[6..10], .little) else 0xffffffff);
            self.say("[MCP_CREATEGAME] \"{s}\" => {s}\n", .{ game.name, res.describe() });
            return res;
        }

        /// Join a game and mint the ticket. The reply names the game server, so this is the only
        /// place that knows where the game physically is.
        pub fn joinGame(self: *Self, name: []const u8, password: []const u8) !Ticket {
            var b: [128]u8 = undefined;
            std.mem.writeInt(u16, b[0..2], 2, .little); // request id
            var w: usize = 2;
            for ([_][]const u8{ name, password }) |part| {
                @memcpy(b[w..][0..part.len], part);
                w += part.len;
                b[w] = 0;
                w += 1;
            }
            try self.mcpSend(MCP_JOINGAME, b[0..w]);
            var mb: [1024]u8 = undefined;
            const r = try self.mcpRecv(MCP_JOINGAME, &mb);
            if (r.len < 18) return Error.ShortReply;

            var ticket = Ticket{
                .gs_ip = .{ r[6], r[7], r[8], r[9] },
                .token = std.mem.readInt(u16, r[2..4], .little),
                .hash = std.mem.readInt(u32, r[10..14], .little),
                .character = self.character,
            };
            // 0.0.0.0 is not an address, it is "wherever you are talking to me from" — a realm
            // that was never told its own public address answers with it. Dialling it fails
            // outright, so fall back to the host we reached the realm on, which is where the game
            // server is too.
            const unspecified = std.mem.allEqual(u8, &ticket.gs_ip, 0);
            const host = if (unspecified)
                std.fmt.bufPrint(&ticket.gs_host_buf, "{s}", .{self.gateway}) catch return Error.ShortReply
            else
                std.fmt.bufPrint(&ticket.gs_host_buf, "{d}.{d}.{d}.{d}", .{ r[6], r[7], r[8], r[9] }) catch return Error.ShortReply;
            ticket.gs_host_len = host.len;

            const res: JoinResult = @enumFromInt(std.mem.readInt(u32, r[14..18], .little));
            self.say("[MCP_JOINGAME] token=0x{x} gs={s} => {s}\n", .{ ticket.token, ticket.gsHost(), res.describe() });
            if (!res.succeeded()) return Error.JoinFailed;
            return ticket;
        }
    };
}

const testing = std.testing;

/// A transport that plays back a recorded server and remembers what was written. Everything above
/// is wire format and sequencing, and both are testable without a socket.
const Replay = struct {
    var script: []const u8 = "";
    var read_at: usize = 0;
    var sent: [4096]u8 = undefined;
    var sent_len: usize = 0;
    var opened: usize = 0;

    pub const Stream = u8;

    fn reset(s: []const u8) void {
        script = s;
        read_at = 0;
        sent_len = 0;
        opened = 0;
    }

    pub fn connect(host: []const u8, port: u16) !Stream {
        _ = host;
        _ = port;
        opened += 1;
        return @intCast(opened);
    }

    pub fn read(s: Stream, buf: []u8) !usize {
        _ = s;
        if (read_at >= script.len) return 0;
        const n = @min(buf.len, script.len - read_at);
        @memcpy(buf[0..n], script[read_at..][0..n]);
        read_at += n;
        return n;
    }

    pub fn writeAll(s: Stream, bytes: []const u8) !void {
        _ = s;
        @memcpy(sent[sent_len..][0..bytes.len], bytes);
        sent_len += bytes.len;
    }

    pub fn close(s: Stream) void {
        _ = s;
    }
};

fn bncsFrame(id: u8, body: []const u8, out: []u8) []u8 {
    out[0] = 0xFF;
    out[1] = id;
    std.mem.writeInt(u16, out[2..4], @intCast(body.len + 4), .little);
    @memcpy(out[4..][0..body.len], body);
    return out[0 .. 4 + body.len];
}

test "a ping mid-handshake is echoed rather than swallowed" {
    // Two frames arrive before the one asked for: a ping, then the answer. A client that does not
    // echo the ping gets dropped by the server, and a client that echoes it in the wrong place
    // corrupts the stream — so the test is about the reply as much as the parse.
    var buf: [128]u8 = undefined;
    var w: usize = 0;
    w += bncsFrame(SID_PING, &[_]u8{ 0xaa, 0xbb, 0xcc, 0xdd }, buf[w..]).len;
    w += bncsFrame(SID_LOGONRESPONSE2, &[_]u8{ 0, 0, 0, 0 }, buf[w..]).len;
    Replay.reset(buf[0..w]);

    var s = Session(Replay){ .opts = .{ .host = "x" }, .bncs = 1 };
    var out: [64]u8 = undefined;
    const body = try s.recvUntil(SID_LOGONRESPONSE2, &out);
    try testing.expectEqual(@as(usize, 4), body.len);

    // The echo carries the ping's payload back verbatim, and nothing else was written.
    try testing.expectEqual(@as(usize, 8), Replay.sent_len);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xFF, SID_PING, 8, 0, 0xaa, 0xbb, 0xcc, 0xdd }, Replay.sent[0..8]);
}

test "a frame split across two reads is still one frame" {
    var buf: [64]u8 = undefined;
    const frame = bncsFrame(SID_AUTH_CHECK, &[_]u8{ 1, 2, 3, 4, 5, 6 }, &buf);
    Replay.reset(frame);

    var s = Session(Replay){ .opts = .{ .host = "x" }, .bncs = 1 };
    // A one-byte read window forces the reassembly path: without it the loop only ever sees whole
    // frames and the partial-frame branch is never taken.
    s.rx_len = 0;
    var out: [64]u8 = undefined;
    const body = try s.recvUntil(SID_AUTH_CHECK, &out);
    try testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3, 4, 5, 6 }, body);
}

test "a length that does not fit the buffer is a bad frame, not a copy past the end" {
    var buf: [32]u8 = .{ 0xFF, SID_AUTH_INFO, 0xff, 0xff } ++ @as([28]u8, @splat(0));
    Replay.reset(&buf);
    var s = Session(Replay){ .opts = .{ .host = "x" }, .bncs = 1 };
    var out: [8]u8 = undefined;
    try testing.expectError(Error.BadFrame, s.recvUntil(SID_AUTH_INFO, &out));
}

/// Write the flags field the way the wire carries it: fourteen bits over two bytes, seven each,
/// high bit forced on so neither can be zero.
fn putFlags(stat: []u8, flags: u16) void {
    stat[26] = @intCast((flags & 0x7f) | 0x80);
    stat[27] = @intCast(((flags >> 7) & 0x7f) | 0x80);
}

test "the statstring is where class, level and edition come from" {
    var c: Character = .{};
    var stat: [34]u8 = @splat(0);
    stat[13] = 7; // class 6, the druid: the wire carries class+1
    stat[25] = 42;
    putFlags(&stat, 0x20); // expansion, nothing else
    readStatString(&stat, &c);
    try testing.expectEqual(@as(u8, 6), c.class);
    try testing.expectEqual(@as(u8, 42), c.level);
    try testing.expect(c.expansion);
    try testing.expect(!c.hardcore);

    // A classic character clears the bit, and a zero class byte is class 0 rather than an
    // underflow to 255.
    putFlags(&stat, 0);
    stat[13] = 0;
    readStatString(&stat, &c);
    try testing.expect(!c.expansion);
    try testing.expectEqual(@as(u8, 0), c.class);
}

test "the flags are fourteen-bit, so a raw read confuses hardcore with the expansion" {
    // Hardcore alone. Read raw, byte 26 comes out 0x84 and every test for the 0x04 bit passes —
    // which is exactly what made every character list back classic.
    var c: Character = .{};
    var stat: [34]u8 = @splat(0);
    putFlags(&stat, 0x04);
    readStatString(&stat, &c);
    try testing.expect(c.hardcore);
    try testing.expect(!c.expansion);

    // Everything at once, plus a progression in the high byte.
    putFlags(&stat, (3 << 8) | 0x04 | 0x08 | 0x20 | 0x40);
    readStatString(&stat, &c);
    try testing.expect(c.hardcore and c.dead and c.expansion and c.ladder);
    try testing.expectEqual(@as(u8, 3), c.progression);

    // A statstring cut off before the flags leaves them at their defaults rather than reading
    // past the end.
    var short: [27]u8 = @splat(0);
    short[13] = 1;
    var d: Character = .{ .expansion = false };
    readStatString(&short, &d);
    try testing.expect(!d.expansion);
}
