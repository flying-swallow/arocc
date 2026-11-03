//! Development-only generator for test/c3/bigint_tests.c3 vectors.
//!
//! Run with the Zig 0.17.0 binary (NOT part of any build; production targets never
//! depend on Zig):
//!
//!     /home/user/tools/zig/ziglang/zig run test/migration/bigint_vectors.zig 2> vectors.txt
//!
//! It prints C3 struct literals (`{ "op", a, b, sign, bits, "r", "r2", flag },`)
//! computed with std.math.big.int from Zig 0.17.0. `a`/`b` index `values` below
//! (mirrored as VALUES in the C3 test), except: shl/shr b = shift amount, tostr
//! b = base, toint b = 0 u64 / 1 i64 / 2 u32 / 3 i32, limit a = 0 min / 1 max,
//! sslc a = base, b = string length. sign: 0 signed, 1 unsigned. Results are
//! signed hexadecimal ("-1f"), parsed in C3 with BigIntMutable.set_string(16, ...).
//! The output (VALUES and VECTORS arrays) goes verbatim between the GENERATED
//! markers of test/c3/bigint_tests.c3.
//!
//! Semantics notes:
//!   - "mulw" follows Aro's Value.mul: exact product, overflow = !fitsInTwosComp,
//!     then truncate. The wrapped value is also cross-checked against Mutable.mulWrap.
//!   - "addw"/"subw"/"mulw"/"not" are only generated for operands that fit the
//!     type, matching how Aro calls them.
//!   - Zig 0.17.0 toString in bases 8/32 is wrong for multi-limb values (see below).
//!   - Zig 0.17.0 bitOr has an uninitialised-limb bug (see the "or" vectors).
//!   - Zig 0.17.0 returns a "-0" remainder for exact negative divisions; the C3 port
//!     normalizes zero to positive, so zero results are printed without a sign.
const std = @import("std");
const big = std.math.big;
const Managed = big.int.Managed;
const Mutable = big.int.Mutable;
const Limb = big.Limb;
const Signedness = std.builtin.Signedness;

var gpa_state: std.heap.DebugAllocator(.{}) = .init;

fn hex(alloc: std.mem.Allocator, c: big.int.Const) ![]u8 {
    if (c.eqlZero()) return alloc.dupe(u8, "0");
    return c.toStringAlloc(alloc, 16, .lower);
}

fn parse(alloc: std.mem.Allocator, s: []const u8) !Managed {
    var m = try Managed.init(alloc);
    try m.setString(16, s);
    return m;
}

fn emit(op: []const u8, a: usize, b: usize, sign: u8, bits: usize, r: []const u8, r2: []const u8, flag: bool) void {
    std.debug.print("\t{{ \"{s}\", {d}, {d}, {d}, {d}, \"{s}\", \"{s}\", {} }},\n", .{ op, a, b, sign, bits, r, r2, flag });
}

fn sgn(s: Signedness) u8 {
    return if (s == .signed) 0 else 1;
}

const values = [_][]const u8{
    "0",
    "1",
    "-1",
    "7f",
    "-80",
    "ff",
    "7fffffffffffffff",
    "-8000000000000000",
    "ffffffffffffffff",
    "10000000000000000",
    "-10000000000000000",
    "1fffffffffffffffe", // 2^65 - 2
    "7fffffffffffffffffffffffffffffff", // i128 max
    "-80000000000000000000000000000000", // i128 min
    "ffffffffffffffffffffffffffffffff", // u128 max
    "100000000000000000000000000000000", // 2^128
    "-123456789abcdef0fedcba98765432100000000000000001", // ~185 bits
    "deadbeefcafebabe0123456789abcdef00000000000000000000000000000001ffff", // ~264 bits
    "-ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff", // -(2^256 - 1)
};

const types = [_]struct { s: Signedness, bits: usize }{
    .{ .s = .unsigned, .bits = 1 },
    .{ .s = .signed, .bits = 1 },
    .{ .s = .unsigned, .bits = 8 },
    .{ .s = .signed, .bits = 8 },
    .{ .s = .unsigned, .bits = 64 },
    .{ .s = .signed, .bits = 64 },
    .{ .s = .signed, .bits = 65 },
    .{ .s = .unsigned, .bits = 128 },
    .{ .s = .signed, .bits = 128 },
    .{ .s = .signed, .bits = 257 },
};

const shifts = [_]usize{ 0, 1, 7, 63, 64, 65, 127, 128, 129, 200, 300 };
const bases = [_]u8{ 2, 3, 7, 8, 10, 16, 32, 36 };

pub fn main() !void {
    const alloc = gpa_state.allocator();
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const ar = arena_state.allocator();

    var r = try Managed.init(ar);
    var r2 = try Managed.init(ar);

    std.debug.print("const String[] VALUES = {{\n", .{});
    for (values) |as| std.debug.print("\t\"{s}\",\n", .{as});
    std.debug.print("}};\n\nconst Vec[] VECTORS = {{\n", .{});
    defer std.debug.print("}};\n", .{});

    // Exact binary ops, division, bitwise ops.
    for (values, 0..) |as, ai| {
        for (values, 0..) |bs, bi| {
            var a = try parse(ar, as);
            var b = try parse(ar, bs);
            try r.add(&a, &b);
            emit("add", ai, bi, 0, 0, try hex(ar, r.toConst()), "", false);
            try r.sub(&a, &b);
            emit("sub", ai, bi, 0, 0, try hex(ar, r.toConst()), "", false);
            try r.mul(&a, &b);
            emit("mul", ai, bi, 0, 0, try hex(ar, r.toConst()), "", false);
            try r.bitAnd(&a, &b);
            emit("and", ai, bi, 0, 0, try hex(ar, r.toConst()), "", false);
            // Zig 0.17.0 Mutable.bitOr leaves the upper limbs of r uninitialised when
            // the longer operand is negative, the shorter one positive and r does not
            // alias the longer operand (llsignedor stops once the borrow is consumed).
            // Computing in place on a copy of the longer operand avoids that bug.
            {
                const a_longer = a.len() >= b.len();
                var t = try (if (a_longer) a else b).clone();
                try t.bitOr(&t, if (a_longer) &b else &a);
                emit("or", ai, bi, 0, 0, try hex(ar, t.toConst()), "", false);
            }
            try r.bitXor(&a, &b);
            emit("xor", ai, bi, 0, 0, try hex(ar, r.toConst()), "", false);
            if (!b.eqlZero()) {
                try r.divTrunc(&r2, &a, &b);
                emit("divt", ai, bi, 0, 0, try hex(ar, r.toConst()), try hex(ar, r2.toConst()), false);
                try r.divFloor(&r2, &a, &b);
                emit("divf", ai, bi, 0, 0, try hex(ar, r.toConst()), try hex(ar, r2.toConst()), false);
            }
        }
    }

    // Wrapping ops, truncate, saturate, not, fits, limits.
    for (types) |t| {
        try r.setTwosCompIntLimit(.min, t.s, t.bits);
        emit("limit", 0, 0, sgn(t.s), t.bits, try hex(ar, r.toConst()), "", false);
        try r.setTwosCompIntLimit(.max, t.s, t.bits);
        emit("limit", 1, 0, sgn(t.s), t.bits, try hex(ar, r.toConst()), "", false);
        for (values, 0..) |as, ai| {
            var a = try parse(ar, as);
            const fits = a.toConst().fitsInTwosComp(t.s, t.bits);
            emit("fits", ai, 0, sgn(t.s), t.bits, "", "", fits);
            try r.truncate(&a, t.s, t.bits);
            emit("trunc", ai, 0, sgn(t.s), t.bits, try hex(ar, r.toConst()), "", false);
            try r.copy(a.toConst());
            try r.saturate(&r, t.s, t.bits);
            emit("sat", ai, 0, sgn(t.s), t.bits, try hex(ar, r.toConst()), "", false);
            if (!fits) continue;
            try r.bitNotWrap(&a, t.s, t.bits);
            emit("not", ai, 0, sgn(t.s), t.bits, try hex(ar, r.toConst()), "", false);
            for (values, 0..) |bs, bi| {
                var b = try parse(ar, bs);
                if (!b.toConst().fitsInTwosComp(t.s, t.bits)) continue;
                var ov = try r.addWrap(&a, &b, t.s, t.bits);
                emit("addw", ai, bi, sgn(t.s), t.bits, try hex(ar, r.toConst()), "", ov);
                ov = try r.subWrap(&a, &b, t.s, t.bits);
                emit("subw", ai, bi, sgn(t.s), t.bits, try hex(ar, r.toConst()), "", ov);
                // Value.mul: exact product, then fits check and truncate.
                try r.mul(&a, &b);
                ov = !r.toConst().fitsInTwosComp(t.s, t.bits);
                if (ov) try r.truncate(&r, t.s, t.bits);
                try r2.mulWrap(&a, &b, t.s, t.bits);
                if (!r.toConst().eql(r2.toConst())) @panic("mulWrap disagrees with mul+truncate");
                emit("mulw", ai, bi, sgn(t.s), t.bits, try hex(ar, r.toConst()), "", ov);
            }
        }
    }

    // Shifts and bit counts.
    for (values, 0..) |as, ai| {
        var a = try parse(ar, as);
        const bc = a.toConst().bitCountTwosComp();
        const bca = a.toConst().bitCountAbs();
        emit("bits", ai, 0, 0, 0, try std.fmt.allocPrint(ar, "{d}", .{bc}), try std.fmt.allocPrint(ar, "{d}", .{bca}), false);
        for (shifts) |sh| {
            try r.shiftLeft(&a, sh);
            emit("shl", ai, sh, 0, 0, try hex(ar, r.toConst()), "", false);
            try r.shiftRight(&a, sh);
            emit("shr", ai, sh, 0, 0, try hex(ar, r.toConst()), "", false);
        }
    }

    // to_string in several bases (lower and upper case).
    for (values, 0..) |as, ai| {
        var a = try parse(ar, as);
        for (bases) |base| {
            // Zig 0.17.0 toString for bases 8 and 32 extracts digits per limb and
            // drops bits that straddle limbs (it even overruns the buffer), so those
            // bases are only generated for single-limb values; bigint_tests.c3 checks
            // multi-limb octal/base-32 against regrouped base-2 output instead.
            if ((base == 8 or base == 32) and a.toConst().limbs.len > 1) continue;
            const lower = try a.toConst().toStringAlloc(ar, base, .lower);
            const upper = try a.toConst().toStringAlloc(ar, base, .upper);
            emit("tostr", ai, base, 0, 0, lower, upper, false);
        }
    }

    // toInt conversions: flag = ok, r = value (decimal) or error name.
    for (values, 0..) |as, ai| {
        var a = try parse(ar, as);
        inline for (.{ u64, i64, u32, i32 }, 0..) |T, idx| {
            if (a.toConst().toInt(T)) |v| {
                emit("toint", ai, idx, 0, 0, try std.fmt.allocPrint(ar, "{d}", .{v}), "", true);
            } else |e| {
                emit("toint", ai, idx, 0, 0, @errorName(e), "", false);
            }
        }
    }

    // calcSetStringLimbCount reference values (r = Zig's count).
    for (bases) |base| {
        for ([_]usize{ 0, 1, 2, 19, 20, 39, 64, 65, 100, 1000, 19729, 65536 }) |len| {
            emit("sslc", base, len, 0, 0, try std.fmt.allocPrint(ar, "{d}", .{big.int.calcSetStringLimbCount(base, len)}), "", false);
        }
    }
}
