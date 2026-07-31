//! D2 1.14d skill/missile calc-string evaluator — a faithful port of the FOG calc expression
//! system (D2Common SKILLS_CompileSkillFormula 0x6c0bc0 + SKILLDESC_EvalDescCalcValue 0x646... +
//! the SkillCalc.txt keyword dictionary). Every Skills.txt/Missiles.txt `*calc` column (damage,
//! synergy EDmgSymPerCalc, duration, aura range, passive value, mana, ...) is one of these
//! expressions; evaluating them is what makes the whole skill catalog table-driven.
//!
//! GRAMMAR (eD2SkillCalcToken + the AST opcode map, DataTbls/Skills.cpp):
//!   ternary  := compare ('?' ternary ':' ternary)?
//!   compare  := add (('=='|'!='|'<'|'<='|'>'|'>=') add)*
//!   add      := mul (('+'|'-') mul)*
//!   mul      := unary (('*'|'/'|'%') unary)*
//!   unary    := '-' unary | primary
//!   primary  := number | '(' ternary ')' | func '(' args ')' | keyword
//!   func     := min | max | rand | skill | stat | miss   (the 7 gaSkillCalcMethods)
//!   keyword  := a SkillCalc.txt `code` (lnAB / dmAB / parN / lvl / ulvl / blvl / ...)
//!
//! KEYWORD SEMANTICS come straight from SkillCalc.txt's *desc (the game's own documentation, which
//! matches the recon math):
//!   lnAB = ParamA + lvl*ParamB                                    (linear)
//!   dmAB = ((110*lvl)*(ParamB-ParamA))/(100*(lvl+6)) + ParamA     (diminishing; == CalcDiminishingReturns)
//!   parN = ParamN                                                  lvl = skill level
//!   ulvl = unit (char) level                                       blvl = base (hard-point) level
//! A `skill('Name'.code)` re-evaluates `code` in the context of the named skill (its params / the
//! caster's level in it) — this is how synergies reference other skills.
//!
//! The caller supplies a `ctx` (see Context below) that resolves per-skill params + the caster's
//! levels; the evaluator itself is pure and holds no game state.

const std = @import("std");

/// Diminishing-returns curve (SKILLS_CalcDiminishingReturns @1.14d 00645b20): grows from `a`
/// toward `b` with diminishing per-level gain, capped at `b`.
pub fn diminishing(level: i64, a: i64, b: i64) i64 {
    const r = @divTrunc(@divTrunc(110 * level, level + 6) * (b - a), 100) + a;
    return if (b >= r) r else b;
}

/// The result of resolving a SkillCalc keyword against a (skill, level) context.
/// `Kw` is a keyword the evaluator recognizes structurally (ln/dm/par/lvl/ulvl/blvl); everything
/// else (edmn/edmx/aura/passive/... damage codes) is delegated to `ctx.keyword` so the host can
/// wire the damage model incrementally without changing the parser.
pub const CalcError = error{ SyntaxError, UnknownKeyword, UnknownFunc, Overflow };

/// What a `skill('Name'.code)` / keyword needs from the game: params, the caster's levels, name
/// resolution, and a fallback for damage/aura/passive codes not handled structurally here.
///   fn param(self, skill_id: u16, n: u8) i32          // ParamN (1..8) of a skill
///   fn level(self, skill_id: u16) i32                 // caster effective level in a skill (lvl)
///   fn baseLevel(self, skill_id: u16) i32             // caster hard-point level (blvl)
///   fn charLevel(self) i32                            // ulvl
///   fn idByName(self, name: []const u8) ?u16          // resolve skill('Name')
///   fn keyword(self, skill_id: u16, level: i32, code: []const u8) ?i32  // edmn/edln/aura/... (null => 0)
/// The current skill for bare keywords (parN/lvl without a skill(...) wrapper) is `skill_id`.
pub fn Evaluator(comptime Ctx: type) type {
    return struct {
        ctx: Ctx,

        const Self = @This();

        /// Evaluate `expr` for skill `skill_id` at effective `level`. Pure integer arithmetic.
        pub fn eval(self: Self, expr: []const u8, skill_id: u16, level: i32) CalcError!i32 {
            var p = Parser{ .src = expr, .self = &self, .skill = skill_id, .level = level };
            const v = try p.ternary();
            p.skipWs();
            if (p.i != p.src.len) return error.SyntaxError;
            return std.math.cast(i32, v) orelse error.Overflow;
        }

        const Parser = struct {
            src: []const u8,
            i: usize = 0,
            self: *const Self,
            skill: u16,
            level: i32,

            fn skipWs(p: *Parser) void {
                while (p.i < p.src.len and (p.src[p.i] == ' ' or p.src[p.i] == '\t')) p.i += 1;
            }
            fn peek(p: *Parser) u8 {
                return if (p.i < p.src.len) p.src[p.i] else 0;
            }
            fn eat(p: *Parser, c: u8) bool {
                p.skipWs();
                if (p.peek() == c) {
                    p.i += 1;
                    return true;
                }
                return false;
            }

            fn ternary(p: *Parser) CalcError!i64 {
                const cond = try p.compare();
                p.skipWs();
                if (p.eat('?')) {
                    const a = try p.ternary();
                    if (!p.eat(':')) return error.SyntaxError;
                    const b = try p.ternary();
                    return if (cond != 0) a else b;
                }
                return cond;
            }

            fn compare(p: *Parser) CalcError!i64 {
                var lhs = try p.addSub();
                while (true) {
                    p.skipWs();
                    const c0 = p.peek();
                    const c1: u8 = if (p.i + 1 < p.src.len) p.src[p.i + 1] else 0;
                    var op: u8 = 0;
                    var two = false;
                    if (c0 == '=' and c1 == '=') {
                        op = '=';
                        two = true;
                    } else if (c0 == '!' and c1 == '=') {
                        op = '!';
                        two = true;
                    } else if (c0 == '<' and c1 == '=') {
                        op = 'l';
                        two = true;
                    } else if (c0 == '>' and c1 == '=') {
                        op = 'g';
                        two = true;
                    } else if (c0 == '<') {
                        op = '<';
                    } else if (c0 == '>') {
                        op = '>';
                    } else break;
                    p.i += if (two) @as(usize, 2) else 1;
                    const rhs = try p.addSub();
                    lhs = @intFromBool(switch (op) {
                        '=' => lhs == rhs,
                        '!' => lhs != rhs,
                        'l' => lhs <= rhs,
                        'g' => lhs >= rhs,
                        '<' => lhs < rhs,
                        '>' => lhs > rhs,
                        else => unreachable,
                    });
                }
                return lhs;
            }

            fn addSub(p: *Parser) CalcError!i64 {
                var lhs = try p.mulDiv();
                while (true) {
                    p.skipWs();
                    const c = p.peek();
                    if (c == '+') {
                        p.i += 1;
                        lhs += try p.mulDiv();
                    } else if (c == '-') {
                        p.i += 1;
                        lhs -= try p.mulDiv();
                    } else break;
                }
                return lhs;
            }

            fn mulDiv(p: *Parser) CalcError!i64 {
                var lhs = try p.unary();
                while (true) {
                    p.skipWs();
                    const c = p.peek();
                    if (c == '*') {
                        p.i += 1;
                        lhs *= try p.unary();
                    } else if (c == '/') {
                        p.i += 1;
                        const r = try p.unary();
                        lhs = if (r == 0) 0 else @divTrunc(lhs, r);
                    } else if (c == '%') {
                        p.i += 1;
                        const r = try p.unary();
                        lhs = if (r == 0) 0 else @rem(lhs, r);
                    } else break;
                }
                return lhs;
            }

            fn unary(p: *Parser) CalcError!i64 {
                p.skipWs();
                if (p.peek() == '-') {
                    p.i += 1;
                    return -(try p.unary());
                }
                return p.primary();
            }

            fn primary(p: *Parser) CalcError!i64 {
                p.skipWs();
                const c = p.peek();
                if (c == '(') {
                    p.i += 1;
                    const v = try p.ternary();
                    if (!p.eat(')')) return error.SyntaxError;
                    return v;
                }
                if (std.ascii.isDigit(c)) return p.number();
                if (std.ascii.isAlphabetic(c)) return p.identifier();
                return error.SyntaxError;
            }

            fn number(p: *Parser) CalcError!i64 {
                var v: i64 = 0;
                while (p.i < p.src.len and std.ascii.isDigit(p.src[p.i])) : (p.i += 1) {
                    v = v * 10 + (p.src[p.i] - '0');
                }
                return v;
            }

            /// A bare word: either a function call `name(...)` or a SkillCalc keyword.
            fn identifier(p: *Parser) CalcError!i64 {
                const start = p.i;
                while (p.i < p.src.len and (std.ascii.isAlphanumeric(p.src[p.i]))) p.i += 1;
                const word = p.src[start..p.i];
                p.skipWs();
                if (p.peek() == '(') return p.callFunc(word);
                return p.self.keyword(word, p.skill, p.level);
            }

            fn callFunc(p: *Parser, name: []const u8) CalcError!i64 {
                _ = p.eat('('); // consume '('
                if (std.mem.eql(u8, name, "skill") or std.mem.eql(u8, name, "miss") or std.mem.eql(u8, name, "stat")) {
                    return p.callSkillLike(name);
                }
                // Numeric-arg functions: min/max/rand.
                const a = try p.ternary();
                var b: i64 = 0;
                if (p.eat(',')) b = try p.ternary();
                if (!p.eat(')')) return error.SyntaxError;
                if (std.mem.eql(u8, name, "min")) return @min(a, b);
                if (std.mem.eql(u8, name, "max")) return @max(a, b);
                if (std.mem.eql(u8, name, "rand")) return a; // deterministic lower bound (no RNG in calc eval)
                return error.UnknownFunc;
            }

            /// `skill('Name'.code)` / `miss('Name'.code)` / `stat('name'.field)`.
            fn callSkillLike(p: *Parser, func: []const u8) CalcError!i64 {
                p.skipWs();
                if (p.peek() != '\'') return error.SyntaxError;
                p.i += 1;
                const ns = p.i;
                while (p.i < p.src.len and p.src[p.i] != '\'') p.i += 1;
                const nm = p.src[ns..p.i];
                if (!p.eat('\'')) return error.SyntaxError;
                var code: []const u8 = "";
                if (p.eat('.')) {
                    const cs = p.i;
                    while (p.i < p.src.len and std.ascii.isAlphanumeric(p.src[p.i])) p.i += 1;
                    code = p.src[cs..p.i];
                }
                if (!p.eat(')')) return error.SyntaxError;
                if (!std.mem.eql(u8, func, "skill")) return 0; // miss()/stat() deferred
                const target = p.self.ctx.idByName(nm) orelse return 0;
                // Re-evaluate `code` in the target skill's context, at the caster's level in it.
                const tgt_level = p.self.ctx.level(target);
                return p.self.keyword(code, target, tgt_level);
            }
        };

        /// Resolve a SkillCalc keyword to its value for (skill_id, level). Structural keywords
        /// (ln/dm/par/lvl/ulvl/blvl) are handled here; the rest delegate to ctx.keyword.
        fn keyword(self: *const Self, word: []const u8, skill_id: u16, level: i32) CalcError!i64 {
            const lvl: i64 = level;
            // lnAB / dmAB
            if (word.len == 4 and std.ascii.isDigit(word[2]) and std.ascii.isDigit(word[3])) {
                const a_idx = word[2] - '0';
                const b_idx = word[3] - '0';
                if (a_idx >= 1 and a_idx <= 8 and b_idx >= 1 and b_idx <= 8) {
                    const a: i64 = self.ctx.param(skill_id, @intCast(a_idx));
                    const b: i64 = self.ctx.param(skill_id, @intCast(b_idx));
                    if (word[0] == 'l' and word[1] == 'n') return a + lvl * b;
                    if (word[0] == 'd' and word[1] == 'm') return diminishing(lvl, a, b);
                }
            }
            // parN
            if (word.len == 4 and std.mem.eql(u8, word[0..3], "par") and std.ascii.isDigit(word[3])) {
                const n = word[3] - '0';
                if (n >= 1 and n <= 8) return self.ctx.param(skill_id, @intCast(n));
            }
            if (std.mem.eql(u8, word, "lvl")) return lvl;
            if (std.mem.eql(u8, word, "ulvl")) return self.ctx.charLevel();
            if (std.mem.eql(u8, word, "blvl")) return self.ctx.baseLevel(skill_id);
            // Anything else (edmn/edmx/edln/aura*/passive*/mana/...) — delegate; unknown => 0.
            if (self.ctx.keyword(skill_id, level, word)) |v| return v;
            return 0;
        }
    };
}

// ---------------------------------------------------------------------------
// Tests — a tiny fixed Context so the evaluator can be exercised without the real Skills table.
// ---------------------------------------------------------------------------
const testing = std.testing;

const TestCtx = struct {
    // params[skill][0..8]
    params: []const [8]i32,
    levels: []const i32,
    clvl: i32 = 1,
    names: []const []const u8,

    fn param(self: TestCtx, skill_id: u16, n: u8) i32 {
        return self.params[skill_id][n - 1];
    }
    fn level(self: TestCtx, skill_id: u16) i32 {
        return self.levels[skill_id];
    }
    fn baseLevel(self: TestCtx, skill_id: u16) i32 {
        return self.levels[skill_id];
    }
    fn charLevel(self: TestCtx) i32 {
        return self.clvl;
    }
    fn idByName(self: TestCtx, name: []const u8) ?u16 {
        for (self.names, 0..) |n, i| if (std.mem.eql(u8, n, name)) return @intCast(i);
        return null;
    }
    fn keyword(self: TestCtx, skill_id: u16, lvl: i32, code: []const u8) ?i32 {
        _ = self;
        _ = skill_id;
        _ = lvl;
        _ = code;
        return null;
    }
};

fn evalWith(ctx: TestCtx, expr: []const u8, skill: u16, level: i32) !i32 {
    const E = Evaluator(TestCtx);
    return (E{ .ctx = ctx }).eval(expr, skill, level);
}

test "arithmetic + precedence + parens + ternary" {
    const ctx = TestCtx{ .params = &.{.{ 0, 0, 0, 0, 0, 0, 0, 0 }}, .levels = &.{1}, .names = &.{"x"} };
    try testing.expectEqual(@as(i32, 14), try evalWith(ctx, "2+3*4", 0, 1));
    try testing.expectEqual(@as(i32, 20), try evalWith(ctx, "(2+3)*4", 0, 1));
    try testing.expectEqual(@as(i32, 7), try evalWith(ctx, "min(7,10)", 0, 1));
    try testing.expectEqual(@as(i32, 10), try evalWith(ctx, "max(7,10)", 0, 1));
    try testing.expectEqual(@as(i32, 99), try evalWith(ctx, "3>2?99:0", 0, 1));
    try testing.expectEqual(@as(i32, 5), try evalWith(ctx, "-5+10", 0, 1));
}

test "ln is linear (a+lvl*b); dm is diminishing (matches CalcDiminishingReturns)" {
    // Cold Mastery-like: Param1=20, Param2=5.
    const ctx = TestCtx{ .params = &.{.{ 20, 5, 0, 0, 0, 0, 0, 0 }}, .levels = &.{1}, .names = &.{"cm"} };
    // ln12 = 20 + lvl*5.
    try testing.expectEqual(@as(i32, 25), try evalWith(ctx, "ln12", 0, 1));
    try testing.expectEqual(@as(i32, 45), try evalWith(ctx, "ln12", 0, 5));
    // dm12 = ((110*lvl)*(5-20))/(100*(lvl+6)) + 20, capped at max=5.
    try testing.expectEqual(diminishing(1, 20, 5), @as(i64, try evalWith(ctx, "dm12", 0, 1)));
    // par1 = Param1.
    try testing.expectEqual(@as(i32, 20), try evalWith(ctx, "par1", 0, 9));
}

test "synergy calc: (skill('a'.blvl)+skill('b'.blvl))*par8 evaluates from the referenced skills" {
    // skill 0 = Ice Bolt-like with Param8=15; skills 1,2 are synergies the caster has 20/10 in.
    const ctx = TestCtx{
        .params = &.{ .{ 0, 0, 0, 0, 0, 0, 0, 15 }, .{0} ** 8, .{0} ** 8 },
        .levels = &.{ 1, 20, 10 },
        .names = &.{ "Ice Bolt", "Frost Nova", "Blizzard" },
    };
    // (20 + 10) * 15 = 450.
    try testing.expectEqual(@as(i32, 450), try evalWith(ctx, "(skill('Frost Nova'.blvl)+skill('Blizzard'.blvl))*par8", 0, 1));
}
