//! Development-only generator for the integer constant differential vectors in
//! test/c3/data/integer_values/. Nothing in a production or Bazel target uses it.
//!
//! Usage (pinned standalone Zig, see test/c3/data/integer_values/README.md):
//!   zig run test/migration/value_probe.zig -- test/c3/data/integer_values
//!
//! The Aro tree needs Zig 0.18-dev and cannot be imported from here, so the
//! integer paths of src/aro/Value.zig (intCast, minUnsignedBits, minSignedBits,
//! add, sub, mul, div, rem, bitOr, bitXor, bitAnd, bitNot, shl, shr, minInt,
//! maxInt, compare) are ported below as close to verbatim as possible. The only
//! changes are mechanical: an interned `Value` becomes `?Const` (null is the
//! `.none` value), `comp.gpa` becomes an arena, and a `QualType` becomes an
//! explicit (signedness, bit count) pair. All big-integer work is done by the
//! std.math.big.int that ships with the Zig binary running this file.
//!
//! Every vector is also cross-checked against an independent full-precision
//! computation (exact result, then reduction modulo 2^bits) before it is
//! written, so a porting slip here aborts generation instead of producing data.

const std = @import("std");
const assert = std.debug.assert;
const Limb = std.math.big.Limb;
const BigIntConst = std.math.big.int.Const;
const BigIntMutable = std.math.big.int.Mutable;
const Managed = std.math.big.int.Managed;
const Signedness = std.builtin.Signedness;

var arena_state: std.heap.ArenaAllocator = undefined;
var gpa: std.mem.Allocator = undefined;

/// `Value` with the interner removed. `null` is `Value{}` (opt_ref == .none).
const Value = ?BigIntConst;

/// `QualType` reduced to what the integer paths read from it.
const IntTy = struct {
    sign: Signedness,
    bits: usize,
    fn signedness(t: IntTy) Signedness {
        return t.sign;
    }
    fn bitSizeof(t: IntTy) usize {
        return t.bits;
    }
};

fn oom() noreturn {
    @panic("out of memory");
}

/// Fresh limb buffers are filled with 0xaa..., the byte pattern Zig Debug
/// builds give `undefined` memory, so that any read of uninitialised limbs by
/// std.math.big.int (see the bit_or note in README.md) is deterministic.
fn allocLimbs(n: usize) []Limb {
    const limbs = gpa.alloc(Limb, n) catch oom();
    @memset(limbs, 0xaaaa_aaaa_aaaa_aaaa);
    return limbs;
}

/// Copy a (possibly stack- or scratch-backed) Const into the arena, the way
/// interning it would.
fn intern(c: BigIntConst) BigIntConst {
    const limbs = allocLimbs(c.limbs.len);
    @memcpy(limbs, c.limbs);
    return .{ .limbs = limbs, .positive = c.positive };
}

fn fromInt(x: anytype) BigIntConst {
    var m = Managed.initSet(gpa, x) catch oom();
    return m.toConst();
}

// ---------------------------------------------------------------------------
// Verbatim-ish ports of src/aro/Value.zig integer paths
// ---------------------------------------------------------------------------

const IntCastChangeKind = enum { none, truncated, sign_changed };

/// Value.minUnsignedBits
fn minUnsignedBits(big: BigIntConst) usize {
    assert(big.positive);
    return big.bitCountAbs();
}

/// Value.minSignedBits
fn minSignedBits(big: BigIntConst) usize {
    assert(!big.positive);
    return big.bitCountTwosComp();
}

/// Value.intCast (integer keys only).
fn intCast(big: BigIntConst, dest_ty: IntTy) struct { BigIntConst, IntCastChangeKind } {
    const dest_bits: usize = dest_ty.bitSizeof();
    const dest_signed = dest_ty.signedness() == .signed;

    const value_bits = big.bitCountTwosComp();

    // if big is negative, then is signed.
    const src_signed = !big.positive;
    const sign_change = src_signed != dest_signed;

    const limbs = allocLimbs(std.math.big.int.calcTwosCompLimbCount(@max(value_bits, dest_bits)));

    var result_bigint = BigIntMutable{ .limbs = limbs, .positive = undefined, .len = undefined };
    result_bigint.truncate(big, dest_ty.signedness(), dest_bits);

    const out = intern(result_bigint.toConst());

    const truncation_occurred = value_bits > dest_bits;
    if (truncation_occurred) {
        return .{ out, .truncated };
    } else if (sign_change) {
        return .{ out, .sign_changed };
    } else {
        return .{ out, .none };
    }
}

/// Value.add, integer path.
fn add(lhs_bigint: BigIntConst, rhs_bigint: BigIntConst, qt: IntTy) struct { BigIntConst, bool } {
    const bits: usize = qt.bitSizeof();
    const limbs = allocLimbs(std.math.big.int.calcTwosCompLimbCount(bits));
    var result_bigint = BigIntMutable{ .limbs = limbs, .positive = undefined, .len = undefined };
    const overflowed = result_bigint.addWrap(lhs_bigint, rhs_bigint, qt.signedness(), bits);
    return .{ intern(result_bigint.toConst()), overflowed };
}

/// Value.sub, integer path.
fn sub(lhs_bigint: BigIntConst, rhs_bigint: BigIntConst, qt: IntTy) struct { BigIntConst, bool } {
    const bits: usize = qt.bitSizeof();
    const limbs = allocLimbs(std.math.big.int.calcTwosCompLimbCount(bits));
    var result_bigint = BigIntMutable{ .limbs = limbs, .positive = undefined, .len = undefined };
    const overflowed = result_bigint.subWrap(lhs_bigint, rhs_bigint, qt.signedness(), bits);
    return .{ intern(result_bigint.toConst()), overflowed };
}

/// Value.mul, integer path.
fn mul(lhs_bigint: BigIntConst, rhs_bigint: BigIntConst, qt: IntTy) struct { BigIntConst, bool } {
    const limbs = allocLimbs(lhs_bigint.limbs.len + rhs_bigint.limbs.len);
    var result_bigint = BigIntMutable{ .limbs = limbs, .positive = undefined, .len = undefined };

    const limbs_buffer = allocLimbs(
        std.math.big.int.calcMulLimbsBufferLen(lhs_bigint.limbs.len, rhs_bigint.limbs.len, 1),
    );

    result_bigint.mul(lhs_bigint, rhs_bigint, limbs_buffer, gpa);

    const bits: usize = qt.bitSizeof();
    const signedness = qt.signedness();
    const overflowed = !result_bigint.toConst().fitsInTwosComp(signedness, bits);
    if (overflowed) {
        result_bigint.truncate(result_bigint.toConst(), signedness, bits);
    }
    return .{ intern(result_bigint.toConst()), overflowed };
}

/// Value.div, integer path. caller guarantees rhs != 0
fn div(lhs_bigint: BigIntConst, rhs_bigint: BigIntConst, qt: IntTy) struct { BigIntConst, bool } {
    const limbs_q = allocLimbs(lhs_bigint.limbs.len);
    var result_q = BigIntMutable{ .limbs = limbs_q, .positive = undefined, .len = undefined };
    const limbs_r = allocLimbs(rhs_bigint.limbs.len);
    var result_r = BigIntMutable{ .limbs = limbs_r, .positive = undefined, .len = undefined };
    const limbs_buffer = allocLimbs(
        std.math.big.int.calcDivLimbsBufferLen(lhs_bigint.limbs.len, rhs_bigint.limbs.len),
    );

    result_q.divTrunc(&result_r, lhs_bigint, rhs_bigint, limbs_buffer);

    const bits: usize = qt.bitSizeof();
    const out = intern(result_q.toConst());
    return .{ out, !result_q.toConst().fitsInTwosComp(qt.signedness(), bits) };
}

/// Value.compare for two integers.
fn compareEq(a: BigIntConst, b: BigIntConst) bool {
    return a.order(b) == .eq;
}

/// Value.rem. caller guarantees rhs != 0
fn rem(lhs_bigint: BigIntConst, rhs_bigint: BigIntConst, qt: IntTy) Value {
    if (qt.signedness() == .signed) {
        var spaces: [2][2]Limb = undefined;
        const min_val = minInt(qt);
        const negative = BigIntMutable.init(&spaces[0], -1).toConst();
        const big_one = BigIntMutable.init(&spaces[1], 1).toConst();
        if (compareEq(lhs_bigint, min_val) and rhs_bigint.eql(negative)) {
            return null;
        } else if (rhs_bigint.order(big_one).compare(.lt)) {
            // lhs - @divTrunc(lhs, rhs) * rhs
            var tmp: BigIntConst = undefined;
            tmp, _ = div(lhs_bigint, rhs_bigint, qt);
            tmp, _ = mul(tmp, rhs_bigint, qt);
            tmp, _ = sub(lhs_bigint, tmp, qt);
            return tmp;
        }
    }

    const limbs_q = allocLimbs(lhs_bigint.limbs.len);
    var result_q = BigIntMutable{ .limbs = limbs_q, .positive = undefined, .len = undefined };
    const limbs_r = allocLimbs(rhs_bigint.limbs.len);
    var result_r = BigIntMutable{ .limbs = limbs_r, .positive = undefined, .len = undefined };
    const limbs_buffer = allocLimbs(
        std.math.big.int.calcDivLimbsBufferLen(lhs_bigint.limbs.len, rhs_bigint.limbs.len),
    );

    result_q.divTrunc(&result_r, lhs_bigint, rhs_bigint, limbs_buffer);
    return intern(result_r.toConst());
}

/// Value.bitOr
fn bitOr(lhs_bigint: BigIntConst, rhs_bigint: BigIntConst) BigIntConst {
    const limbs = allocLimbs(@max(lhs_bigint.limbs.len, rhs_bigint.limbs.len));
    var result_bigint = BigIntMutable{ .limbs = limbs, .positive = undefined, .len = undefined };
    result_bigint.bitOr(lhs_bigint, rhs_bigint);
    return intern(result_bigint.toConst());
}

/// Value.bitXor
fn bitXor(lhs_bigint: BigIntConst, rhs_bigint: BigIntConst) BigIntConst {
    const extra = @intFromBool(lhs_bigint.positive != rhs_bigint.positive);
    const limbs = allocLimbs(@max(lhs_bigint.limbs.len, rhs_bigint.limbs.len) + extra);
    var result_bigint = BigIntMutable{ .limbs = limbs, .positive = undefined, .len = undefined };
    result_bigint.bitXor(lhs_bigint, rhs_bigint);
    return intern(result_bigint.toConst());
}

/// Value.bitAnd
fn bitAnd(lhs_bigint: BigIntConst, rhs_bigint: BigIntConst) BigIntConst {
    const limb_count = if (lhs_bigint.positive and rhs_bigint.positive)
        @min(lhs_bigint.limbs.len, rhs_bigint.limbs.len)
    else if (lhs_bigint.positive)
        lhs_bigint.limbs.len
    else if (rhs_bigint.positive)
        rhs_bigint.limbs.len
    else
        @max(lhs_bigint.limbs.len, rhs_bigint.limbs.len) + 1;

    const limbs = allocLimbs(limb_count);
    var result_bigint = BigIntMutable{ .limbs = limbs, .positive = undefined, .len = undefined };
    result_bigint.bitAnd(lhs_bigint, rhs_bigint);
    return intern(result_bigint.toConst());
}

/// Value.bitNot
fn bitNot(val_bigint: BigIntConst, qt: IntTy) BigIntConst {
    const bits: usize = qt.bitSizeof();
    const limbs = allocLimbs(std.math.big.int.calcTwosCompLimbCount(bits));
    var result_bigint = BigIntMutable{ .limbs = limbs, .positive = undefined, .len = undefined };
    result_bigint.bitNotWrap(val_bigint, qt.signedness(), bits);
    return intern(result_bigint.toConst());
}

/// Value.toInt(usize, ...)
fn toUsize(v: BigIntConst) ?usize {
    return v.toInt(usize) catch null;
}

/// Value.shl
fn shl(lhs_bigint: BigIntConst, rhs: BigIntConst, qt: IntTy) struct { BigIntConst, bool } {
    const shift = toUsize(rhs) orelse std.math.maxInt(usize);

    const bits: usize = qt.bitSizeof();
    if (shift > bits) {
        if (lhs_bigint.positive) {
            return .{ maxInt(qt), true };
        } else {
            return .{ minInt(qt), true };
        }
    }

    const limbs = allocLimbs(lhs_bigint.limbs.len + (shift / (@sizeOf(Limb) * 8)) + 1);
    var result_bigint = BigIntMutable{ .limbs = limbs, .positive = undefined, .len = undefined };

    result_bigint.shiftLeft(lhs_bigint, shift);
    const signedness = qt.signedness();
    const overflowed = !result_bigint.toConst().fitsInTwosComp(signedness, bits);
    if (overflowed) {
        result_bigint.truncate(result_bigint.toConst(), signedness, bits);
    }
    return .{ intern(result_bigint.toConst()), overflowed };
}

/// Value.shr
fn shr(lhs_bigint: BigIntConst, rhs: BigIntConst, qt: IntTy) BigIntConst {
    const shift = toUsize(rhs) orelse return fromInt(0);

    const result_limbs = lhs_bigint.limbs.len -| (shift / (@sizeOf(Limb) * 8));
    if (result_limbs == 0) {
        // The shift is enough to remove all the bits from the number, which means the
        // result is 0 or -1 depending on the sign.
        if (lhs_bigint.positive) {
            return fromInt(0);
        } else {
            return fromInt(@as(i64, -1));
        }
    }

    const bits: usize = qt.bitSizeof();
    const limbs = allocLimbs(std.math.big.int.calcTwosCompLimbCount(bits));
    var result_bigint = BigIntMutable{ .limbs = limbs, .positive = undefined, .len = undefined };

    result_bigint.shiftRight(lhs_bigint, shift);
    return intern(result_bigint.toConst());
}

/// Value.twosCompIntLimit
fn twosCompIntLimit(limit: std.math.big.int.TwosCompIntLimit, qt: IntTy) BigIntConst {
    const signedness = qt.signedness();
    if (limit == .min and signedness == .unsigned) return fromInt(0);
    const mag_bits: usize = qt.bitSizeof();
    switch (mag_bits) {
        inline 8, 16, 32, 64 => |bits| {
            if (limit == .min) return fromInt(@as(i64, std.math.minInt(@Int(.signed, bits))));
            return switch (signedness) {
                inline else => |sign| fromInt(std.math.maxInt(@Int(sign, bits))),
            };
        },
        else => {},
    }

    const sign_bits = @intFromBool(signedness == .signed);
    const total_bits = mag_bits + sign_bits;

    const limbs = allocLimbs(std.math.big.int.calcTwosCompLimbCount(total_bits));

    var result_bigint: BigIntMutable = .{ .limbs = limbs, .positive = undefined, .len = undefined };
    result_bigint.setTwosCompIntLimit(limit, signedness, mag_bits);
    return intern(result_bigint.toConst());
}

fn minInt(qt: IntTy) BigIntConst {
    return twosCompIntLimit(.min, qt);
}

fn maxInt(qt: IntTy) BigIntConst {
    return twosCompIntLimit(.max, qt);
}

// ---------------------------------------------------------------------------
// Independent full-precision reference used only for cross-checking
// ---------------------------------------------------------------------------

fn toM(c: BigIntConst) Managed {
    return c.toManaged(gpa) catch oom();
}

fn refAdd(a: BigIntConst, b: BigIntConst) BigIntConst {
    var r = Managed.init(gpa) catch oom();
    var ma = toM(a);
    var mb = toM(b);
    r.add(&ma, &mb) catch oom();
    return r.toConst();
}

fn refSub(a: BigIntConst, b: BigIntConst) BigIntConst {
    var r = Managed.init(gpa) catch oom();
    var ma = toM(a);
    var mb = toM(b);
    r.sub(&ma, &mb) catch oom();
    return r.toConst();
}

fn refMul(a: BigIntConst, b: BigIntConst) BigIntConst {
    var r = Managed.init(gpa) catch oom();
    var ma = toM(a);
    var mb = toM(b);
    r.mul(&ma, &mb) catch oom();
    return r.toConst();
}

/// Truncating quotient and remainder.
fn refDivTrunc(a: BigIntConst, b: BigIntConst) struct { BigIntConst, BigIntConst } {
    var q = Managed.init(gpa) catch oom();
    var r = Managed.init(gpa) catch oom();
    var ma = toM(a);
    var mb = toM(b);
    q.divTrunc(&r, &ma, &mb) catch oom();
    return .{ q.toConst(), r.toConst() };
}

/// Flooring quotient.
fn refDivFloor(a: BigIntConst, b: BigIntConst) BigIntConst {
    var q = Managed.init(gpa) catch oom();
    var r = Managed.init(gpa) catch oom();
    var ma = toM(a);
    var mb = toM(b);
    q.divFloor(&r, &ma, &mb) catch oom();
    return q.toConst();
}

fn pow2(n: usize) BigIntConst {
    var r = Managed.initSet(gpa, 1) catch oom();
    r.shiftLeft(&r, n) catch oom();
    return r.toConst();
}

fn refMin(sign: Signedness, bits: usize) BigIntConst {
    return if (sign == .unsigned) fromInt(0) else pow2(bits - 1).negate();
}

fn refMax(sign: Signedness, bits: usize) BigIntConst {
    return refSub(if (sign == .unsigned) pow2(bits) else pow2(bits - 1), fromInt(1));
}

fn refFits(x: BigIntConst, sign: Signedness, bits: usize) bool {
    return x.order(refMin(sign, bits)) != .lt and x.order(refMax(sign, bits)) != .gt;
}

/// Two's-complement wrap of an exact value into (sign, bits).
fn refWrap(x: BigIntConst, sign: Signedness, bits: usize) BigIntConst {
    const modulus = pow2(bits);
    const q = refDivFloor(x, modulus);
    var r = refSub(x, refMul(q, modulus)); // 0 <= r < 2^bits
    if (sign == .signed and r.order(pow2(bits - 1)) != .lt) r = refSub(r, modulus);
    return r;
}

const BitOp = enum { @"and", @"or", xor };

/// Independent bitwise reference: wrap both operands to a common unsigned
/// width W wide enough for both (plus a sign bit), apply the op on the
/// non-negative values (the trivially correct positive/positive std path),
/// then reinterpret the W-bit result as signed.
fn refBitwise(comptime op: BitOp, a: BigIntConst, b: BigIntConst) BigIntConst {
    const W = @max(a.bitCountTwosComp(), b.bitCountTwosComp()) + 2;
    var ua = toM(refWrap(a, .unsigned, W));
    var ub = toM(refWrap(b, .unsigned, W));
    var r = Managed.init(gpa) catch oom();
    switch (op) {
        .@"and" => r.bitAnd(&ua, &ub) catch oom(),
        .@"or" => r.bitOr(&ua, &ub) catch oom(),
        .xor => r.bitXor(&ua, &ub) catch oom(),
    }
    return refWrap(r.toConst(), .signed, W);
}

fn check(ok: bool, what: []const u8) void {
    if (!ok) {
        std.debug.print("cross-check failed: {s}\n", .{what});
        @panic("cross-check failed");
    }
}

fn eq(a: BigIntConst, b: BigIntConst) bool {
    return a.order(b) == .eq;
}

// ---------------------------------------------------------------------------
// Output
// ---------------------------------------------------------------------------

const PROV_RUN = "zig-0.17.0";
const PROV_ARO = "aro-test";
const PROV_BUG = "zig-0.17.0-stdbug";
var bug_count: usize = 0;

/// `[-]0x<lowercase hex>`
fn writeHex(w: *std.Io.Writer, c: BigIntConst) !void {
    const abs = c.abs();
    const buf = gpa.alloc(u8, abs.sizeInBaseUpperBound(16) + 1) catch oom();
    const n = abs.toString(buf, 16, .lower, &.{});
    if (!c.positive and !c.eqlZero()) try w.writeAll("-");
    try w.writeAll("0x");
    try w.writeAll(buf[0..n]);
}

const Field = union(enum) {
    none, // `_`
    val: BigIntConst,
    opt: Value, // value or `none`
    dec: usize,
    word: []const u8,
};

fn writeField(w: *std.Io.Writer, f: Field) !void {
    switch (f) {
        .none => try w.writeAll("_"),
        .val => |c| try writeHex(w, c),
        .opt => |o| if (o) |c| try writeHex(w, c) else try w.writeAll("none"),
        .dec => |d| try w.print("{d}", .{d}),
        .word => |s| try w.writeAll(s),
    }
}

fn signWord(s: Signedness) []const u8 {
    return if (s == .signed) "s" else "u";
}

fn line(
    w: *std.Io.Writer,
    count: *usize,
    op: []const u8,
    ty: ?IntTy,
    lhs: Field,
    rhs: Field,
    result: Field,
    flag: []const u8,
    prov: []const u8,
) !void {
    try w.writeAll(op);
    if (ty) |t| {
        try w.print(" {s} {d} ", .{ signWord(t.sign), t.bits });
    } else {
        try w.writeAll(" _ _ ");
    }
    try writeField(w, lhs);
    try w.writeAll(" ");
    try writeField(w, rhs);
    try w.writeAll(" ");
    try writeField(w, result);
    try w.print(" {s} {s}\n", .{ flag, prov });
    count.* += 1;
}

fn header(w: *std.Io.Writer, title: []const u8, ops: []const u8) !void {
    try w.print(
        \\# {s}
        \\# Generated by test/migration/value_probe.zig (dev-only); do not edit by hand.
        \\# Format: see README.md in this directory.
        \\#   op sign bits lhs rhs result flag provenance
        \\# Ops in this file: {s}
        \\# Provenance "{s}": computed by running the verbatim port of src/aro/Value.zig
        \\#   integer logic on std.math.big.int from the Zig 0.17.0 binary, and
        \\#   cross-checked against an exact full-precision reference.
        \\# Provenance "{s}": expectation copied from an embedded `test` block in
        \\#   src/aro/Value.zig, and also reproduced by the same Zig 0.17.0 run.
        \\# Provenance "{s}": the verbatim port hit a std.math.big.int defect in
        \\#   Zig 0.17.0; the vector holds the exact two's-complement result from the
        \\#   independent reference, and the preceding comment shows the defective output.
        \\
    , .{ title, ops, PROV_RUN, PROV_ARO, PROV_BUG });
}

// ---------------------------------------------------------------------------
// Operand selection
// ---------------------------------------------------------------------------

/// splitmix64, fixed seed: stable across Zig versions, unlike std.Random.
var rng_state: u64 = 0x0a70_c3c0_dead_beef;
fn nextU64() u64 {
    rng_state +%= 0x9e3779b97f4a7c15;
    var z = rng_state;
    z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
    return z ^ (z >> 31);
}

/// Pseudo-random non-negative value with exactly `nbits` random bits.
fn randomBits(nbits: usize) BigIntConst {
    const n = (nbits + 63) / 64;
    var acc = Managed.initSet(gpa, 0) catch oom();
    var i: usize = 0;
    while (i < n) : (i += 1) {
        acc.shiftLeft(&acc, 64) catch oom();
        var limb = Managed.initSet(gpa, nextU64()) catch oom();
        acc.add(&acc, &limb) catch oom();
    }
    return refWrap(acc.toConst(), .unsigned, nbits);
}

/// 0x5555... over `nbits` bits.
fn pattern55(nbits: usize) BigIntConst {
    var acc = Managed.initSet(gpa, 0) catch oom();
    var i: usize = 0;
    while (i < nbits) : (i += 2) {
        acc.shiftLeft(&acc, 2) catch oom();
        var one = Managed.initSet(gpa, 1) catch oom();
        acc.add(&acc, &one) catch oom();
    }
    return refWrap(acc.toConst(), .unsigned, nbits);
}

/// In-range interesting operands for a type.
fn operands(t: IntTy) []BigIntConst {
    var list: std.ArrayList(BigIntConst) = .empty;
    const min = refMin(t.sign, t.bits);
    const max = refMax(t.sign, t.bits);
    const cands = [_]BigIntConst{
        fromInt(0),
        fromInt(1),
        fromInt(2),
        fromInt(3),
        fromInt(-1),
        fromInt(-2),
        max,
        refSub(max, fromInt(1)),
        min,
        refAdd(min, fromInt(1)),
        refWrap(pattern55(t.bits), t.sign, t.bits),
        refWrap(randomBits(t.bits), t.sign, t.bits),
        refWrap(randomBits(t.bits), t.sign, t.bits),
    };
    for (cands) |c| {
        if (!refFits(c, t.sign, t.bits)) continue;
        var dup = false;
        for (list.items) |e| if (eq(e, c)) {
            dup = true;
        };
        if (!dup) list.append(gpa, c) catch oom();
    }
    return list.items;
}

const widths = [_]usize{ 8, 13, 16, 32, 63, 64, 65, 127, 128, 129, 200, 256 };
const signs = [_]Signedness{ .unsigned, .signed };

fn allTypes() []IntTy {
    var list: std.ArrayList(IntTy) = .empty;
    for (widths) |b| for (signs) |s| list.append(gpa, .{ .sign = s, .bits = b }) catch oom();
    return list.items;
}

/// Values of assorted magnitudes for bit counts, casts and bitwise ops,
/// including values wider than every destination type.
fn wideValues() []BigIntConst {
    var list: std.ArrayList(BigIntConst) = .empty;
    const app = struct {
        fn f(l: *std.ArrayList(BigIntConst), c: BigIntConst) void {
            for (l.items) |e| if (eq(e, c)) return;
            l.append(gpa, c) catch oom();
        }
    }.f;
    app(&list, fromInt(0));
    app(&list, fromInt(1));
    app(&list, fromInt(-1));
    app(&list, fromInt(5));
    app(&list, fromInt(-5));
    app(&list, fromInt(-101));
    const pts = [_]usize{ 7, 8, 15, 16, 31, 32, 63, 64, 65, 127, 128, 129, 191, 192, 255, 256, 257, 300 };
    for (pts) |p| {
        const pp = pow2(p);
        app(&list, pp); // 2^p
        app(&list, refSub(pp, fromInt(1))); // 2^p - 1
        app(&list, pp.negate()); // -2^p
        app(&list, refSub(fromInt(0), refAdd(pp, fromInt(1)))); // -2^p - 1
    }
    const rnd = [_]usize{ 40, 100, 140, 250, 280 };
    for (rnd) |b| {
        const r = randomBits(b);
        app(&list, r);
        app(&list, r.negate());
    }
    return list.items;
}

// ---------------------------------------------------------------------------
// Generators
// ---------------------------------------------------------------------------

fn genBitCounts(w: *std.Io.Writer) !usize {
    var n: usize = 0;
    try header(w, "minUnsignedBits / minSignedBits (Value.minUnsignedBits, Value.minSignedBits)", "min_unsigned_bits min_signed_bits");

    // Expectations from `test "minUnsignedBits"` / `test "minSignedBits"` in Value.zig.
    const aro_u = [_]struct { u64, usize }{
        .{ 0, 0 },                               .{ 1, 1 },                              .{ 2, 2 },
        .{ std.math.maxInt(i8), 7 },             .{ std.math.maxInt(u8), 8 },            .{ std.math.maxInt(i16), 15 },
        .{ std.math.maxInt(u16), 16 },           .{ std.math.maxInt(i32), 31 },          .{ std.math.maxInt(u32), 32 },
        .{ std.math.maxInt(i64), 63 },           .{ std.math.maxInt(u64), 64 },
    };
    for (aro_u) |c| {
        const v = fromInt(c[0]);
        const got = minUnsignedBits(v);
        check(got == c[1], "aro minUnsignedBits");
        try line(w, &n, "min_unsigned_bits", null, .{ .val = v }, .none, .{ .dec = got }, "_", PROV_ARO);
    }
    const aro_s = [_]struct { i64, usize }{
        .{ -1, 1 },                         .{ -2, 2 },                          .{ -10, 5 },
        .{ -101, 8 },                       .{ std.math.minInt(i8), 8 },         .{ std.math.minInt(i16), 16 },
        .{ std.math.minInt(i32), 32 },      .{ std.math.minInt(i64), 64 },
    };
    for (aro_s) |c| {
        const v = fromInt(c[0]);
        const got = minSignedBits(v);
        check(got == c[1], "aro minSignedBits");
        try line(w, &n, "min_signed_bits", null, .{ .val = v }, .none, .{ .dec = got }, "_", PROV_ARO);
    }

    for (wideValues()) |v| {
        if (v.positive) {
            const got = minUnsignedBits(v);
            // reference: smallest b with v < 2^b
            var b: usize = 0;
            while (v.order(pow2(b)) != .lt) b += 1;
            check(got == b, "minUnsignedBits ref");
            try line(w, &n, "min_unsigned_bits", null, .{ .val = v }, .none, .{ .dec = got }, "_", PROV_RUN);
        } else {
            const got = minSignedBits(v);
            // reference: smallest b with v >= -2^(b-1)
            var b: usize = 1;
            while (v.order(pow2(b - 1).negate()) == .lt) b += 1;
            check(got == b, "minSignedBits ref");
            try line(w, &n, "min_signed_bits", null, .{ .val = v }, .none, .{ .dec = got }, "_", PROV_RUN);
        }
    }
    return n;
}

fn genLimits(w: *std.Io.Writer) !usize {
    var n: usize = 0;
    try header(w, "minInt / maxInt (Value.minInt, Value.maxInt via twosCompIntLimit)", "min_int max_int");
    const extra_widths = [_]usize{ 1, 2, 7, 24, 48, 96, 255 };
    var all: std.ArrayList(IntTy) = .empty;
    for (allTypes()) |t| all.append(gpa, t) catch oom();
    for (extra_widths) |b| for (signs) |s| {
        if (s == .signed and b < 2) continue;
        all.append(gpa, .{ .sign = s, .bits = b }) catch oom();
    };
    for (all.items) |t| {
        const lo = minInt(t);
        check(eq(lo, refMin(t.sign, t.bits)), "minInt ref");
        try line(w, &n, "min_int", t, .none, .none, .{ .val = lo }, "_", PROV_RUN);
        const hi = maxInt(t);
        check(eq(hi, refMax(t.sign, t.bits)), "maxInt ref");
        try line(w, &n, "max_int", t, .none, .none, .{ .val = hi }, "_", PROV_RUN);
    }
    return n;
}

fn genIntCast(w: *std.Io.Writer) !usize {
    var n: usize = 0;
    try header(w, "intCast truncation / sign change (Value.intCast)", "int_cast");
    var dests: std.ArrayList(IntTy) = .empty;
    for (allTypes()) |t| dests.append(gpa, t) catch oom();
    dests.append(gpa, .{ .sign = .unsigned, .bits = 1 }) catch oom();
    dests.append(gpa, .{ .sign = .signed, .bits = 2 }) catch oom();

    for (wideValues()) |v| for (dests.items) |t| {
        const res, const kind = intCast(v, t);
        check(eq(res, refWrap(v, t.sign, t.bits)), "intCast value ref");
        const value_bits = v.bitCountTwosComp();
        const ref_kind: IntCastChangeKind = if (value_bits > t.bits)
            .truncated
        else if ((!v.positive) != (t.sign == .signed))
            .sign_changed
        else
            .none;
        check(kind == ref_kind, "intCast kind ref");
        try line(w, &n, "int_cast", t, .{ .val = v }, .none, .{ .val = res }, @tagName(kind), PROV_RUN);
    };
    return n;
}

fn ovf(b: bool) []const u8 {
    return if (b) "overflow" else "ok";
}

fn genArith(w: *std.Io.Writer) !usize {
    var n: usize = 0;
    try header(w, "add / sub / mul / div / rem / order (Value.add, sub, mul, div, rem, compare)", "add sub mul div rem order");
    for (allTypes()) |t| {
        const ops = operands(t);
        for (ops) |a| for (ops) |b| {
            {
                const r, const o = add(a, b, t);
                const exact = refAdd(a, b);
                check(eq(r, refWrap(exact, t.sign, t.bits)) and o == !refFits(exact, t.sign, t.bits), "add ref");
                try line(w, &n, "add", t, .{ .val = a }, .{ .val = b }, .{ .val = r }, ovf(o), PROV_RUN);
            }
            {
                const r, const o = sub(a, b, t);
                const exact = refSub(a, b);
                check(eq(r, refWrap(exact, t.sign, t.bits)) and o == !refFits(exact, t.sign, t.bits), "sub ref");
                try line(w, &n, "sub", t, .{ .val = a }, .{ .val = b }, .{ .val = r }, ovf(o), PROV_RUN);
            }
            {
                const r, const o = mul(a, b, t);
                const exact = refMul(a, b);
                check(eq(r, refWrap(exact, t.sign, t.bits)) and o == !refFits(exact, t.sign, t.bits), "mul ref");
                try line(w, &n, "mul", t, .{ .val = a }, .{ .val = b }, .{ .val = r }, ovf(o), PROV_RUN);
            }
            if (!b.eqlZero()) {
                // Value.div does not wrap the quotient; it only reports overflow.
                const r, const o = div(a, b, t);
                const q, const rr = refDivTrunc(a, b);
                check(eq(r, q) and o == !refFits(q, t.sign, t.bits), "div ref");
                try line(w, &n, "div", t, .{ .val = a }, .{ .val = b }, .{ .val = r }, ovf(o), PROV_RUN);

                const rv = rem(a, b, t);
                if (t.sign == .signed and eq(a, refMin(t.sign, t.bits)) and eq(b, fromInt(-1))) {
                    check(rv == null, "rem none ref");
                } else {
                    check(rv != null and eq(rv.?, rr), "rem ref");
                }
                try line(w, &n, "rem", t, .{ .val = a }, .{ .val = b }, .{ .opt = rv }, "_", PROV_RUN);
            }
            {
                const o = a.order(b);
                try line(w, &n, "order", t, .{ .val = a }, .{ .val = b }, .none, @tagName(o), PROV_RUN);
            }
        };
    }
    return n;
}

fn genShifts(w: *std.Io.Writer) !usize {
    var n: usize = 0;
    try header(w, "shl / shr at boundaries (Value.shl, Value.shr)", "shl shr");
    for (allTypes()) |t| {
        const ops = operands(t);
        const b = t.bits;
        const amounts = [_]BigIntConst{
            fromInt(0),        fromInt(1),          fromInt(2),     fromInt(b - 2),  fromInt(b - 1),
            fromInt(b),        fromInt(b + 1),      fromInt(63),    fromInt(64),     fromInt(65),
            fromInt(127),      fromInt(128),        fromInt(129),   fromInt(300),    fromInt(-1),
            fromInt(-64),      pow2(64), // does not fit usize
            pow2(70),
        };
        var seen: std.ArrayList(BigIntConst) = .empty;
        for (amounts) |s| {
            var dup = false;
            for (seen.items) |e| if (eq(e, s)) {
                dup = true;
            };
            if (!dup) seen.append(gpa, s) catch oom();
        }
        for (ops) |a| for (seen.items) |s| {
            {
                const r, const o = shl(a, s, t);
                const su = toUsize(s);
                if (su == null or su.? > b) {
                    const sat = if (a.positive) refMax(t.sign, b) else refMin(t.sign, b);
                    check(eq(r, sat) and o, "shl saturate ref");
                } else {
                    const exact = refMul(a, pow2(su.?));
                    check(eq(r, refWrap(exact, t.sign, b)) and o == !refFits(exact, t.sign, b), "shl ref");
                }
                try line(w, &n, "shl", t, .{ .val = a }, .{ .val = s }, .{ .val = r }, ovf(o), PROV_RUN);
            }
            {
                const r = shr(a, s, t);
                const su = toUsize(s);
                if (su == null) {
                    check(r.eqlZero(), "shr negative ref");
                } else if (su.? > 4096) {
                    unreachable;
                } else {
                    check(eq(r, refDivFloor(a, pow2(su.?))), "shr ref");
                }
                try line(w, &n, "shr", t, .{ .val = a }, .{ .val = s }, .{ .val = r }, "_", PROV_RUN);
            }
        };
    }
    return n;
}

fn genBitwise(w: *std.Io.Writer) !usize {
    var n: usize = 0;
    try header(w, "bitwise ops (Value.bitAnd, bitOr, bitXor: width-free; Value.bitNot: typed)", "bit_and bit_or bit_xor bit_not");
    // Width-free ops over mixed-magnitude values (both signs, >128-bit).
    const pool = [_]BigIntConst{
        fromInt(0),                         fromInt(-1),                        fromInt(1),
        fromInt(0xff),                      fromInt(-256),                      fromInt(0x1234_5678_9abc_def0),
        refSub(pow2(64), fromInt(1)),       pow2(64).negate(),                  refSub(pow2(128), fromInt(1)),
        pow2(127).negate(),                 pattern55(200),                     pattern55(200).negate(),
        randomBits(256),                    randomBits(190).negate(),           refSub(fromInt(0), pow2(255)),
        randomBits(70),                     randomBits(130).negate(),
    };
    for (pool) |a| for (pool) |b| {
        inline for (.{ BitOp.@"and", BitOp.@"or", BitOp.xor }) |op| {
            const got = switch (op) {
                .@"and" => bitAnd(a, b),
                .@"or" => bitOr(a, b),
                .xor => bitXor(a, b),
            };
            const want = refBitwise(op, a, b);
            const name = "bit_" ++ @tagName(op);
            if (eq(got, want)) {
                try line(w, &n, name, null, .{ .val = a }, .{ .val = b }, .{ .val = got }, "_", PROV_RUN);
            } else {
                // std.math.big.int defect: record the correct two's-complement
                // result and keep the verbatim output in a comment.
                try w.writeAll("# std-bug: verbatim Value." ++ switch (op) {
                    .@"and" => "bitAnd",
                    .@"or" => "bitOr",
                    .xor => "bitXor",
                } ++ " on Zig 0.17.0 returned ");
                try writeHex(w, got);
                try w.writeAll(" (reads uninitialised limbs; 0xaa fill)\n");
                try line(w, &n, name, null, .{ .val = a }, .{ .val = b }, .{ .val = want }, "_", PROV_BUG);
                bug_count += 1;
            }
        }
    };
    for (allTypes()) |t| for (operands(t)) |a| {
        const r = bitNot(a, t);
        check(eq(r, refWrap(refSub(fromInt(-1), a), t.sign, t.bits)), "bitNot ref");
        try line(w, &n, "bit_not", t, .{ .val = a }, .none, .{ .val = r }, "_", PROV_RUN);
    };
    return n;
}

const Gen = struct { file: []const u8, f: *const fn (*std.Io.Writer) anyerror!usize };

pub fn main(init: std.process.Init) !void {
    arena_state = .init(std.heap.page_allocator);
    gpa = arena_state.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(gpa);
    if (args.len != 2) {
        std.debug.print("usage: value_probe <out-dir>\n", .{});
        return error.Usage;
    }
    var dir = try std.Io.Dir.cwd().openDir(io, args[1], .{});
    defer dir.close(io);

    const gens = [_]Gen{
        .{ .file = "bit_counts.txt", .f = genBitCounts },
        .{ .file = "limits.txt", .f = genLimits },
        .{ .file = "int_cast.txt", .f = genIntCast },
        .{ .file = "arith.txt", .f = genArith },
        .{ .file = "shifts.txt", .f = genShifts },
        .{ .file = "bitwise.txt", .f = genBitwise },
    };
    for (gens) |g| {
        var aw: std.Io.Writer.Allocating = .init(gpa);
        const count = try g.f(&aw.writer);
        try aw.writer.print("# end: {d} vectors\n", .{count});
        try dir.writeFile(io, .{ .sub_path = g.file, .data = aw.written() });
        std.debug.print("{s}: {d} vectors\n", .{ g.file, count });
    }
    std.debug.print("std.math.big.int defects worked around: {d}\n", .{bug_count});
}
