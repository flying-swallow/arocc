//! Development-only generator for the float and complex constant vectors in
//! test/c3/data/float_values/. Nothing in a production or Bazel target uses it.
//!
//! Usage (standalone Zig 0.17.0, see test/c3/data/float_values/README.md):
//!   zig run -fllvm -mcpu=baseline test/migration/float_probe.zig -- test/c3/data/float_values
//!
//! The Aro tree needs Zig 0.18-dev and cannot be imported from here, so the
//! float parts of src/aro/Value.zig (floatToInt, intToFloat, toFloat,
//! bigIntToFloat, floatCast, the float/complex branches of add/sub/mul/div,
//! complexAddSub, complexConj, compare, isNan/isInf, the float arms of print)
//! and all of src/aro/annex_g.zig are ported below as close to verbatim as
//! possible. Interned values become plain Zig floats (or big ints), and a
//! QualType becomes a width or a (signedness, bits) pair.
//!
//! Every operand is loaded through a volatile pointer, so all float operations
//! run on the target at run time (never folded by Sema or LLVM). The results are
//! therefore what the selected backend/CPU really computes; the README records
//! how the backends differ (only NaN bit patterns do).
//!
//! Independently of Zig floats, the probe carries an exact big-integer model of
//! IEEE round-to-nearest-even for every format. Every result that model can
//! predict (all non-NaN results of + - * /, casts, int conversions, fma,
//! comparisons, float->int) is checked against it; a disagreement aborts
//! generation. The model also reproduces the reference's *two-step* roundings
//! (bigIntToFloat's per-limb @mulAdd, parseFloat(f128) then @floatCast), and such
//! vectors are tagged `zig-0.17.0-dblround` when they differ from one correct
//! rounding. A disagreement on a compiler_rt / std.math path is recorded as
//! `zig-0.17.0-libbug` (model value, Zig's output in a comment); any other
//! disagreement aborts generation in the canonical configuration
//! (-fllvm -mcpu=baseline). NaN results are checked against the observed NaN
//! rules documented in README.md.

const std = @import("std");
const builtin = @import("builtin");
const math = std.math;
const Managed = std.math.big.int.Managed;
const BigConst = std.math.big.int.Const;
const BigMut = std.math.big.int.Mutable;
const Limb = std.math.big.Limb;
const annex_g = struct {
    // ------------------------------------------------------------------
    // Verbatim copy of src/aro/annex_g.zig (functions only).
    // ------------------------------------------------------------------
    const copysign = std.math.copysign;
    const ilogb = std.math.ilogb;
    const inf = std.math.inf;
    const isFinite = std.math.isFinite;
    const isInf = std.math.isInf;
    const isNan = std.math.isNan;
    const isPositiveZero = std.math.isPositiveZero;
    const scalbn = std.math.scalbn;

    fn complexFloatMul(comptime T: type, a_param: T, b_param: T, c_param: T, d_param: T) [2]T {
        var a = a_param;
        var b = b_param;
        var c = c_param;
        var d = d_param;

        const ac = a * c;
        const bd = b * d;
        const ad = a * d;
        const bc = b * c;
        var x = ac - bd;
        var y = ad + bc;
        if (isNan(x) and isNan(y)) {
            var recalc = false;
            if (isInf(a) or isInf(b)) {
                a = copysign(if (isInf(a)) @as(T, 1.0) else @as(T, 0.0), a);
                b = copysign(if (isInf(b)) @as(T, 1.0) else @as(T, 0.0), b);
                if (isNan(c)) c = copysign(@as(T, 0.0), c);
                if (isNan(d)) d = copysign(@as(T, 0.0), d);
                recalc = true;
            }
            if (isInf(c) or isInf(d)) {
                c = copysign(if (isInf(c)) @as(T, 1.0) else @as(T, 0.0), c);
                d = copysign(if (isInf(d)) @as(T, 1.0) else @as(T, 0.0), d);
                if (isNan(a)) a = copysign(@as(T, 0.0), a);
                if (isNan(b)) b = copysign(@as(T, 0.0), b);
                recalc = true;
            }
            if (!recalc and (isInf(ac) or isInf(bd) or isInf(ad) or isInf(bc))) {
                if (isNan(a)) a = copysign(@as(T, 0.0), a);
                if (isNan(b)) b = copysign(@as(T, 0.0), b);
                if (isNan(c)) c = copysign(@as(T, 0.0), c);
                if (isNan(d)) d = copysign(@as(T, 0.0), d);
            }
            if (recalc) {
                x = inf(T) * (a * c - b * d);
                y = inf(T) * (a * d + b * c);
            }
        }
        return .{ x, y };
    }

    fn complexFloatDiv(comptime T: type, a_param: T, b_param: T, c_param: T, d_param: T) [2]T {
        var a = a_param;
        var b = b_param;
        var c = c_param;
        var d = d_param;
        var denom_logb: i32 = 0;
        const max_cd = @max(@abs(c), @abs(d));
        if (isFinite(max_cd)) {
            if (max_cd == 0) {
                denom_logb = std.math.minInt(i32) + 1;
                c = 0;
                d = 0;
            } else {
                denom_logb = ilogb(max_cd);
                c = scalbn(c, -denom_logb);
                d = scalbn(d, -denom_logb);
            }
        }
        const denom = c * c + d * d;
        var x = scalbn((a * c + b * d) / denom, -denom_logb);
        var y = scalbn((b * c - a * d) / denom, -denom_logb);
        if (isNan(x) and isNan(y)) {
            if (isPositiveZero(denom) and (!isNan(a) or !isNan(b))) {
                x = copysign(inf(T), c) * a;
                y = copysign(inf(T), c) * b;
            } else if ((isInf(a) or isInf(b)) and isFinite(c) and isFinite(d)) {
                a = copysign(if (isInf(a)) @as(T, 1.0) else @as(T, 0.0), a);
                b = copysign(if (isInf(b)) @as(T, 1.0) else @as(T, 0.0), b);
                x = inf(T) * (a * c + b * d);
                y = inf(T) * (b * c - a * d);
            } else if (isInf(max_cd) and isFinite(a) and isFinite(b)) {
                c = copysign(if (isInf(c)) @as(T, 1.0) else @as(T, 0.0), c);
                d = copysign(if (isInf(d)) @as(T, 1.0) else @as(T, 0.0), d);
                x = 0.0 * (a * c + b * d);
                y = 0.0 * (b * c - a * d);
            }
        }
        return .{ x, y };
    }
};

var arena_state: std.heap.ArenaAllocator = undefined;
var gpa: std.mem.Allocator = undefined;

fn oom() noreturn {
    @panic("out of memory");
}

const PROV_EXACT = "zig-0.17.0";
const PROV_RUN = "zig-0.17.0-run";
const PROV_DBL = "zig-0.17.0-dblround";
const PROV_LIB = "zig-0.17.0-libbug";
const PROV_ARO = "aro-test";

const Widths = [_]type{ f16, f32, f64, f80, f128 };

var mismatches: usize = 0;

fn mismatch(comptime fmt: []const u8, args: anytype) void {
    mismatches += 1;
    if (mismatches <= 100000) std.debug.print("MISMATCH: " ++ fmt ++ "\n", args);
}

// ---------------------------------------------------------------------------
// Bit access
// ---------------------------------------------------------------------------

fn Bits(comptime T: type) type {
    return @Int(.unsigned, @bitSizeOf(T));
}

/// Pass a value through a volatile slot so that every use is a run-time value.
fn launder(comptime T: type, x: T) T {
    var v: T = x;
    const p: *volatile T = &v;
    return p.*;
}

fn fromBits(comptime T: type, b: Bits(T)) T {
    return launder(T, @bitCast(b));
}

fn toBits(comptime T: type, x: T) Bits(T) {
    return @bitCast(x);
}

const Fmt = struct { p: u32, ebits: u32, bias: i32, explicit: bool, total: u32 };

fn fmtOf(comptime T: type) Fmt {
    return switch (T) {
        f16 => .{ .p = 11, .ebits = 5, .bias = 15, .explicit = false, .total = 16 },
        f32 => .{ .p = 24, .ebits = 8, .bias = 127, .explicit = false, .total = 32 },
        f64 => .{ .p = 53, .ebits = 11, .bias = 1023, .explicit = false, .total = 64 },
        f80 => .{ .p = 64, .ebits = 15, .bias = 16383, .explicit = true, .total = 80 },
        f128 => .{ .p = 113, .ebits = 15, .bias = 16383, .explicit = false, .total = 128 },
        else => unreachable,
    };
}

fn emaxField(comptime T: type) u32 {
    return (@as(u32, 1) << @intCast((comptime fmtOf(T)).ebits)) - 1;
}

/// Build a bit pattern from sign, biased exponent field and the p-1 stored
/// fraction bits. For f80 the explicit integer bit is set iff biased != 0.
fn mk(comptime T: type, neg: bool, biased: u32, frac: u128) Bits(T) {
    const f = comptime fmtOf(T);
    const fbits = f.p - 1;
    const frac_mask: u128 = (@as(u128, 1) << fbits) - 1;
    const exp_shift = if (f.explicit) 64 else fbits;
    var r: u128 = (@as(u128, biased) << exp_shift) | (frac & frac_mask);
    if (f.explicit and biased != 0) r |= @as(u128, 1) << 63;
    if (neg) r |= @as(u128, 1) << (f.total - 1);
    return @intCast(r);
}

fn signMask(comptime T: type) Bits(T) {
    return @as(Bits(T), 1) << (@bitSizeOf(T) - 1);
}

const Kind = enum { zero, finite, inf, nan, noncanon };
const Dec = struct { neg: bool, kind: Kind, sig: u128 = 0, exp: i32 = 0 };

/// Exact decomposition: finite value = (-1)^neg * sig * 2^exp.
fn decompose(comptime T: type, b: Bits(T)) Dec {
    const f = comptime fmtOf(T);
    const x: u128 = b;
    const neg = ((x >> (f.total - 1)) & 1) == 1;
    const emax = emaxField(T);
    if (f.explicit) {
        const e: u32 = @intCast((x >> 64) & 0x7fff);
        const m: u64 = @truncate(x);
        const int_bit = (m >> 63) == 1;
        if (e == 0) {
            if (m == 0) return .{ .neg = neg, .kind = .zero };
            // denormal, or pseudo-denormal (int bit set) with the exponent of e=1
            return .{ .neg = neg, .kind = if (int_bit) .noncanon else .finite, .sig = m, .exp = 1 - f.bias - 63 };
        }
        if (!int_bit) return .{ .neg = neg, .kind = .noncanon };
        if (e == emax) return .{ .neg = neg, .kind = if ((m << 1) == 0) .inf else .nan, .sig = m & ((@as(u64, 1) << 63) - 1) };
        return .{ .neg = neg, .kind = .finite, .sig = m, .exp = @as(i32, @intCast(e)) - f.bias - 63 };
    }
    const fb = f.p - 1;
    const e: u32 = @intCast((x >> fb) & emax);
    const frac = x & ((@as(u128, 1) << fb) - 1);
    if (e == 0) {
        if (frac == 0) return .{ .neg = neg, .kind = .zero };
        return .{ .neg = neg, .kind = .finite, .sig = frac, .exp = 1 - f.bias - @as(i32, fb) };
    }
    if (e == emax) return .{ .neg = neg, .kind = if (frac == 0) .inf else .nan, .sig = frac };
    return .{ .neg = neg, .kind = .finite, .sig = frac | (@as(u128, 1) << fb), .exp = @as(i32, @intCast(e)) - f.bias - @as(i32, fb) };
}

fn isNanBits(comptime T: type, b: Bits(T)) bool {
    const k = decompose(T, b).kind;
    return k == .nan or k == .noncanon;
}

fn infBits(comptime T: type, neg: bool) Bits(T) {
    return mk(T, neg, emaxField(T), 0);
}

fn zeroBits(comptime T: type, neg: bool) Bits(T) {
    return if (neg) signMask(T) else 0;
}

/// Quiet bit = top stored fraction bit.
fn quietBit(comptime T: type) Bits(T) {
    return @as(Bits(T), 1) << ((comptime fmtOf(T)).p - 2);
}

// ---------------------------------------------------------------------------
// Big integer helpers (arena backed; never freed)
// ---------------------------------------------------------------------------

fn big(x: anytype) Managed {
    return Managed.initSet(gpa, x) catch oom();
}
fn bigShl(a: Managed, n: usize) Managed {
    var r = Managed.init(gpa) catch oom();
    r.shiftLeft(&a, n) catch oom();
    return r;
}
fn bigShr(a: Managed, n: usize) Managed {
    var r = Managed.init(gpa) catch oom();
    r.shiftRight(&a, n) catch oom();
    return r;
}
fn bigAdd(a: Managed, b: Managed) Managed {
    var r = Managed.init(gpa) catch oom();
    r.add(&a, &b) catch oom();
    return r;
}
fn bigSub(a: Managed, b: Managed) Managed {
    var r = Managed.init(gpa) catch oom();
    r.sub(&a, &b) catch oom();
    return r;
}
fn bigMul(a: Managed, b: Managed) Managed {
    var r = Managed.init(gpa) catch oom();
    r.mul(&a, &b) catch oom();
    return r;
}
fn bigNeg(a: Managed) Managed {
    var r = a.clone() catch oom();
    r.negate();
    return r;
}
fn bigAbs(a: Managed) Managed {
    var r = a.clone() catch oom();
    r.abs();
    return r;
}
fn bigPow2(n: usize) Managed {
    return bigShl(big(1), n);
}

/// Signed exact value of a finite decomposition, as (M, e) with M signed.
fn signedSig(d: Dec) Managed {
    const m = big(d.sig);
    return if (d.neg) bigNeg(m) else m;
}

// ---------------------------------------------------------------------------
// Exact IEEE round-to-nearest-even model
// ---------------------------------------------------------------------------

/// Round (-1)^neg * (m + sticky*delta) * 2^e to T (nearest even), m >= 0.
fn roundTo(comptime T: type, neg: bool, m: Managed, e: i64, sticky: bool) Bits(T) {
    const f = comptime fmtOf(T);
    const p: i64 = f.p;
    if (m.eqlZero()) {
        std.debug.assert(!sticky);
        return zeroBits(T, neg);
    }
    const L: i64 = @intCast(m.bitCountAbs());
    const E = L - 1 + e;
    const emin: i64 = 1 - f.bias;
    var q: i64 = @max(E, emin) - (p - 1);
    const shift = q - e;
    var mant: u128 = undefined;
    if (shift <= 0) {
        std.debug.assert(!sticky);
        mant = bigShl(m, @intCast(-shift)).toInt(u128) catch unreachable;
    } else if (shift > L + 1) {
        mant = 0; // far below half of the smallest quantum
    } else {
        const sh: usize = @intCast(shift);
        const hi = bigShr(m, sh);
        mant = hi.toInt(u128) catch unreachable;
        const rem = bigSub(m, bigShl(hi, sh));
        const half = bigPow2(sh - 1);
        const up = switch (rem.order(half)) {
            .gt => true,
            .lt => false,
            .eq => sticky or (mant & 1) == 1,
        };
        if (up) mant += 1;
    }
    if (mant == (@as(u128, 1) << @intCast(p))) {
        mant >>= 1;
        q += 1;
    }
    const emax: i64 = emaxField(T);
    var biased: i64 = 0;
    if ((mant >> @intCast(p - 1)) != 0) {
        biased = q + (p - 1) + f.bias;
        if (biased >= emax) return infBits(T, neg);
    }
    var r: u128 = if (f.explicit)
        (@as(u128, @intCast(biased)) << 64) | mant
    else
        (@as(u128, @intCast(biased)) << @intCast(p - 1)) | (mant & ((@as(u128, 1) << @intCast(p - 1)) - 1));
    if (neg) r |= @as(u128, 1) << (f.total - 1);
    return @intCast(r);
}

/// Round a signed exact value M * 2^e.
fn roundSigned(comptime T: type, m: Managed, e: i64) Bits(T) {
    return roundTo(T, !m.isPositive() and !m.eqlZero(), bigAbs(m), e, false);
}

const Ref = union(enum) { skip, nan, bits: u128 };

const Op = enum {
    add,
    sub,
    mul,
    div,
    fn name(op: Op) []const u8 {
        return @tagName(op);
    }
};

fn refArith(comptime T: type, op: Op, ab: Bits(T), bb: Bits(T)) Ref {
    const a = decompose(T, ab);
    var b = decompose(T, bb);
    if (a.kind == .noncanon or b.kind == .noncanon) return .skip;
    if (a.kind == .nan or b.kind == .nan) return .nan;
    switch (op) {
        .add, .sub => {
            if (op == .sub) b.neg = !b.neg;
            if (a.kind == .inf and b.kind == .inf) return if (a.neg == b.neg) .{ .bits = infBits(T, a.neg) } else .nan;
            if (a.kind == .inf) return .{ .bits = infBits(T, a.neg) };
            if (b.kind == .inf) return .{ .bits = infBits(T, b.neg) };
            if (a.kind == .zero and b.kind == .zero) return .{ .bits = zeroBits(T, a.neg and b.neg) };
            var emin: i64 = std.math.maxInt(i64);
            if (a.kind == .finite) emin = @min(emin, a.exp);
            if (b.kind == .finite) emin = @min(emin, b.exp);
            var s = big(0);
            if (a.kind == .finite) s = bigAdd(s, bigShl(signedSig(a), @intCast(a.exp - emin)));
            if (b.kind == .finite) s = bigAdd(s, bigShl(signedSig(b), @intCast(b.exp - emin)));
            if (s.eqlZero()) return .{ .bits = zeroBits(T, false) };
            return .{ .bits = roundSigned(T, s, emin) };
        },
        .mul => {
            const neg = a.neg != b.neg;
            if ((a.kind == .inf and b.kind == .zero) or (a.kind == .zero and b.kind == .inf)) return .nan;
            if (a.kind == .inf or b.kind == .inf) return .{ .bits = infBits(T, neg) };
            if (a.kind == .zero or b.kind == .zero) return .{ .bits = zeroBits(T, neg) };
            return .{ .bits = roundTo(T, neg, bigMul(big(a.sig), big(b.sig)), @as(i64, a.exp) + b.exp, false) };
        },
        .div => {
            const neg = a.neg != b.neg;
            if ((a.kind == .zero and b.kind == .zero) or (a.kind == .inf and b.kind == .inf)) return .nan;
            if (a.kind == .inf) return .{ .bits = infBits(T, neg) };
            if (b.kind == .inf) return .{ .bits = zeroBits(T, neg) };
            if (b.kind == .zero) return .{ .bits = infBits(T, neg) };
            if (a.kind == .zero) return .{ .bits = zeroBits(T, neg) };
            const k: usize = 260;
            var q = Managed.init(gpa) catch oom();
            var r = Managed.init(gpa) catch oom();
            const n = bigShl(big(a.sig), k);
            const dd = big(b.sig);
            q.divTrunc(&r, &n, &dd) catch oom();
            return .{ .bits = roundTo(T, neg, q, @as(i64, a.exp) - b.exp - @as(i64, k), !r.eqlZero()) };
        },
    }
}

fn refCast(comptime S: type, comptime D: type, sb: Bits(S)) Ref {
    const a = decompose(S, sb);
    return switch (a.kind) {
        .noncanon => .skip,
        .nan => .nan,
        .inf => .{ .bits = infBits(D, a.neg) },
        .zero => .{ .bits = zeroBits(D, a.neg) },
        .finite => .{ .bits = roundTo(D, a.neg, big(a.sig), a.exp, false) },
    };
}

fn modelCast(comptime S: type, comptime D: type, sb: Bits(S)) ?Bits(D) {
    return switch (refCast(S, D, sb)) {
        .skip => null,
        .nan => modelCastNan(S, D, sb),
        .bits => |r| @intCast(r),
    };
}

/// Exact a*b + c for f128 (finite operands only; otherwise skip).
fn refFma(a_b: u128, b_b: u128, c_b: u128) Ref {
    const a = decompose(f128, a_b);
    const b = decompose(f128, b_b);
    const c = decompose(f128, c_b);
    if (a.kind != .finite and a.kind != .zero) return .skip;
    if (b.kind != .finite and b.kind != .zero) return .skip;
    if (c.kind != .finite and c.kind != .zero) return .skip;
    const pneg = a.neg != b.neg;
    const pzero = a.kind == .zero or b.kind == .zero;
    if (pzero and c.kind == .zero) return .{ .bits = zeroBits(f128, pneg and c.neg) };
    var emin: i64 = std.math.maxInt(i64);
    if (!pzero) emin = @min(emin, @as(i64, a.exp) + b.exp);
    if (c.kind == .finite) emin = @min(emin, c.exp);
    var s = big(0);
    if (!pzero) {
        var pm = bigMul(big(a.sig), big(b.sig));
        if (pneg) pm = bigNeg(pm);
        s = bigAdd(s, bigShl(pm, @intCast(@as(i64, a.exp) + b.exp - emin)));
    }
    if (c.kind == .finite) s = bigAdd(s, bigShl(signedSig(c), @intCast(c.exp - emin)));
    if (s.eqlZero()) return .{ .bits = 0 };
    return .{ .bits = roundSigned(f128, s, emin) };
}

/// Exact value of a finite/zero decomposition as a signed big int times 2^exp.
fn refOrder(comptime T: type, ab: Bits(T), bb: Bits(T)) ?math.Order {
    const a = decompose(T, ab);
    const b = decompose(T, bb);
    if (a.kind == .nan or b.kind == .nan or a.kind == .noncanon or b.kind == .noncanon) return null;
    const rank = struct {
        fn r(d: Dec) i2 {
            return switch (d.kind) {
                .inf => if (d.neg) -1 else 1,
                else => 0,
            };
        }
    };
    const ra = rank.r(a);
    const rb = rank.r(b);
    if (ra != 0 or rb != 0) return math.order(ra, rb);
    var emin: i64 = std.math.maxInt(i64);
    if (a.kind == .finite) emin = @min(emin, a.exp);
    if (b.kind == .finite) emin = @min(emin, b.exp);
    const av = if (a.kind == .finite) bigShl(signedSig(a), @intCast(a.exp - emin)) else big(0);
    const bv = if (b.kind == .finite) bigShl(signedSig(b), @intCast(b.exp - emin)) else big(0);
    return av.order(bv);
}

// ---------------------------------------------------------------------------
// Ports of src/aro/Value.zig float paths
// ---------------------------------------------------------------------------

/// Value.zig bigIntToFloat, verbatim (limbs are little-endian u64).
fn bigIntToFloat(limbs: []const Limb, positive: bool) f128 {
    if (limbs.len == 0) return 0;

    const base = std.math.maxInt(Limb) + 1;
    var result: f128 = launder(f128, 0);
    var i: usize = limbs.len;
    while (i != 0) {
        i -= 1;
        const limb: f128 = @as(f128, @floatFromInt(launder(Limb, limbs[i])));
        result = @mulAdd(f128, launder(f128, base), result, limb);
    }
    if (positive) {
        return result;
    } else {
        return -result;
    }
}

/// Exact model of bigIntToFloat: one f128 rounding per limb step.
fn modelBigIntToFloat(limbs: []const Limb, positive: bool) u128 {
    if (limbs.len == 0) return 0;
    var acc: u128 = 0; // f128 bits, non-negative
    var i: usize = limbs.len;
    while (i != 0) {
        i -= 1;
        const d = decompose(f128, acc);
        if (d.kind == .inf) continue;
        // exact = acc * 2^64 + limb
        var emin: i64 = 0;
        if (d.kind == .finite) emin = @min(emin, @as(i64, d.exp) + 64);
        var s = big(limbs[i]);
        s = bigShl(s, @intCast(0 - emin));
        if (d.kind == .finite) s = bigAdd(s, bigShl(big(d.sig), @intCast(@as(i64, d.exp) + 64 - emin)));
        acc = roundTo(f128, false, s, emin, false);
    }
    return if (positive) acc else acc ^ signMask(f128);
}

/// Aro's interner (src/backend/Interner.zig put/get) hands Value.toFloat an
/// int as `.u64` when it fits u32, `.i64` when it is negative and fits i32,
/// and as `.big_int` otherwise.
const IntRepr = enum { u64, i64, big_int };
fn internedRepr(x: Managed) IntRepr {
    if (x.fitsInTwosComp(.unsigned, 32)) return .u64;
    if (x.fitsInTwosComp(.signed, 32)) return .i64;
    return .big_int;
}

/// Value.toFloat(T) of an int key.
fn intToFloatPort(comptime T: type, x: Managed) T {
    switch (internedRepr(x)) {
        .u64 => return @floatFromInt(launder(u64, x.toInt(u64) catch unreachable)),
        .i64 => return @floatFromInt(launder(i64, x.toInt(i64) catch unreachable)),
        .big_int => {
            const c = x.toConst();
            return @floatCast(bigIntToFloat(c.limbs, c.positive));
        },
    }
}

const FloatToIntChangeKind = enum { none, out_of_range, overflow, nonzero_to_zero, value_changed };

const Dest = union(enum) {
    bool,
    int: struct { sign: std.builtin.Signedness, bits: usize },

    fn write(d: Dest, o: *Out) void {
        switch (d) {
            .bool => o.word("bool"),
            .int => |i| {
                o.sep();
                o.w.print("{s}{d}", .{ if (i.sign == .signed) "s" else "u", i.bits }) catch oom();
            },
        }
    }
};

const FloatToIntResult = struct { val: ?BigConst, kind: FloatToIntChangeKind };

/// Value.floatToInt, verbatim apart from the interner (the Value is the returned
/// big int, null = Value{}), given toFloat(f128) of the operand.
fn floatToIntPort(float_val: f128, dest_ty: Dest) FloatToIntResult {
    const was_zero = float_val == 0;

    if (dest_ty == .bool) {
        const was_one = float_val == 1.0;
        const v = big(@intFromBool(!was_zero)).toConst();
        if (was_zero or was_one) return .{ .val = v, .kind = .none };
        return .{ .val = v, .kind = .value_changed };
    } else if (dest_ty.int.sign == .unsigned and float_val < 0) {
        return .{ .val = big(0).toConst(), .kind = .out_of_range };
    } else if (!std.math.isFinite(float_val)) {
        return .{ .val = null, .kind = .overflow };
    }

    const signedness = dest_ty.int.sign;
    const bits: usize = dest_ty.int.bits;

    var big_int: BigMut = .{
        .limbs = gpa.alloc(Limb, @max(
            std.math.big.int.calcLimbLen(float_val),
            std.math.big.int.calcTwosCompLimbCount(bits),
        )) catch oom(),
        .len = undefined,
        .positive = undefined,
    };
    const had_fraction = switch (big_int.setFloat(float_val, .trunc)) {
        .inexact => true,
        .exact => false,
    };

    const fits = big_int.toConst().fitsInTwosComp(signedness, bits);
    const interned = (big_int.toConst().toManaged(gpa) catch oom()).toConst();
    big_int.truncate(big_int.toConst(), signedness, bits);

    if (!was_zero and interned.eqlZero()) return .{ .val = interned, .kind = .nonzero_to_zero };
    if (!fits) return .{ .val = interned, .kind = .out_of_range };
    if (had_fraction) return .{ .val = interned, .kind = .value_changed };
    return .{ .val = interned, .kind = .none };
}

/// Independent model of floatToInt from the exact decomposition of the f128.
fn modelFloatToInt(fb: u128, dest: Dest) FloatToIntResult {
    const d = decompose(f128, fb);
    const was_zero = d.kind == .zero;
    if (dest == .bool) {
        const one = d.kind == .finite and !d.neg and refOrder(f128, fb, toBits(f128, 1.0)) == .eq;
        const v = big(@intFromBool(!was_zero)).toConst();
        return .{ .val = v, .kind = if (was_zero or one) .none else .value_changed };
    }
    if (dest.int.sign == .unsigned and d.neg and d.kind != .zero and d.kind != .nan) return .{ .val = big(0).toConst(), .kind = .out_of_range };
    if (d.kind == .inf or d.kind == .nan) return .{ .val = null, .kind = .overflow };
    if (was_zero) return .{ .val = big(0).toConst(), .kind = .none };
    var t: Managed = undefined;
    var frac = false;
    if (d.exp >= 0) {
        t = bigShl(big(d.sig), @intCast(d.exp));
    } else {
        const sh: usize = @intCast(-d.exp);
        t = bigShr(big(d.sig), sh);
        frac = !bigSub(big(d.sig), bigShl(t, sh)).eqlZero();
    }
    if (d.neg) t = bigNeg(t);
    if (t.eqlZero()) return .{ .val = big(0).toConst(), .kind = .nonzero_to_zero };
    const fits = t.fitsInTwosComp(dest.int.sign, dest.int.bits);
    if (!fits) return .{ .val = t.toConst(), .kind = .out_of_range };
    return .{ .val = t.toConst(), .kind = if (frac) .value_changed else .none };
}

/// Value.print, .float arm.
fn printFloat(comptime T: type, x: T, buf: []u8) []const u8 {
    return switch (T) {
        f16 => std.fmt.bufPrint(buf, "{d}", .{@round(@as(f64, @floatCast(x)) * 1000) / 1000}) catch unreachable,
        f32 => std.fmt.bufPrint(buf, "{d}", .{@round(@as(f64, @floatCast(x)) * 1000000) / 1000000}) catch unreachable,
        else => std.fmt.bufPrint(buf, "{d}", .{@as(f64, @floatCast(x))}) catch unreachable,
    };
}

/// The f64 that printFloat formats (for the round-trip check).
fn printedValue(comptime T: type, x: T) f64 {
    return switch (T) {
        f16 => @round(@as(f64, @floatCast(x)) * 1000) / 1000,
        f32 => @round(@as(f64, @floatCast(x)) * 1000000) / 1000000,
        else => @as(f64, @floatCast(x)),
    };
}

/// Value.print, .complex arm.
fn printComplex(comptime T: type, re: T, im: T, buf: []u8) []const u8 {
    return switch (T) {
        f32 => std.fmt.bufPrint(buf, "{d} + {d}i", .{ @round(@as(f64, @floatCast(re)) * 1000000) / 1000000, @round(@as(f64, @floatCast(im)) * 1000000) / 1000000 }) catch unreachable,
        else => std.fmt.bufPrint(buf, "{d} + {d}i", .{ @as(f64, @floatCast(re)), @as(f64, @floatCast(im)) }) catch unreachable,
    };
}

// ---------------------------------------------------------------------------
// Output
// ---------------------------------------------------------------------------

const Out = struct {
    w: *std.Io.Writer,
    count: usize = 0,
    at_start: bool = true,

    fn sep(o: *Out) void {
        if (!o.at_start) o.w.writeByte(' ') catch oom();
        o.at_start = false;
    }
    fn word(o: *Out, s: []const u8) void {
        o.sep();
        o.w.writeAll(s) catch oom();
    }
    fn ty(o: *Out, comptime T: type) void {
        o.word(@typeName(T));
    }
    fn f(o: *Out, comptime T: type, b: Bits(T)) void {
        o.sep();
        const digits = comptime std.fmt.comptimePrint("{d}", .{(@bitSizeOf(T) + 3) / 4});
        o.w.print("0x{x:0>" ++ digits ++ "}", .{b}) catch oom();
    }
    fn int(o: *Out, c: BigConst) void {
        o.sep();
        const abs = c.abs();
        const buf = gpa.alloc(u8, abs.sizeInBaseUpperBound(16) + 1) catch oom();
        const n = abs.toString(buf, 16, .lower, &.{});
        if (!c.positive and !c.eqlZero()) o.w.writeAll("-") catch oom();
        o.w.writeAll("0x") catch oom();
        o.w.writeAll(buf[0..n]) catch oom();
    }
    fn dec(o: *Out, v: i64) void {
        o.sep();
        o.w.print("{d}", .{v}) catch oom();
    }
    fn str(o: *Out, s: []const u8) void {
        std.debug.assert(std.mem.indexOfScalar(u8, s, '"') == null);
        o.sep();
        o.w.print("\"{s}\"", .{s}) catch oom();
    }
    fn eq(o: *Out) void {
        o.word("=");
    }
    fn end(o: *Out, prov: []const u8) void {
        o.word(prov);
        o.w.writeByte('\n') catch oom();
        o.count += 1;
        o.at_start = true;
    }
    fn comment(o: *Out, comptime fmt: []const u8, args: anytype) void {
        std.debug.assert(o.at_start);
        o.w.print("# " ++ fmt ++ "\n", args) catch oom();
    }
};

fn header(o: *Out, title: []const u8, ops: []const u8) void {
    o.comment("{s}", .{title});
    o.comment("Generated by test/migration/float_probe.zig (dev-only); do not edit by hand.", .{});
    o.comment("Format and provenance tags: see README.md in this directory.", .{});
    o.comment("Ops in this file: {s}", .{ops});
    o.comment("Reference run: Zig {s}, backend {s}, cpu {s}, {s}, x86_64-linux.", .{
        builtin.zig_version_string,
        @tagName(builtin.zig_backend),
        builtin.cpu.model.name,
        @tagName(builtin.mode),
    });
}

// ---------------------------------------------------------------------------
// Operand selection
// ---------------------------------------------------------------------------

/// splitmix64, fixed seed: stable across Zig versions, unlike std.Random.
var rng_state: u64 = 0xf10a_7c3c_0bad_cafe;
fn nextU64() u64 {
    rng_state +%= 0x9e3779b97f4a7c15;
    var z = rng_state;
    z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
    return z ^ (z >> 31);
}
fn nextU128() u128 {
    return (@as(u128, nextU64()) << 64) | nextU64();
}
fn below(n: u64) u64 {
    return nextU64() % n;
}

/// Any canonical bit pattern (f80: integer bit set iff the exponent is nonzero).
fn rndBits(comptime T: type) Bits(T) {
    const r: Bits(T) = @truncate(nextU128());
    if (T == f80) {
        const e = (r >> 64) & 0x7fff;
        const m = r & ((@as(u80, 1) << 63) - 1);
        return (r & ~@as(u80, (@as(u80, 1) << 64) - 1)) | m | (if (e != 0) @as(u80, 1) << 63 else 0);
    }
    return r;
}

/// Normal number with |unbiased exponent| <= spread.
fn rndNormal(comptime T: type, spread: u32) Bits(T) {
    const f = comptime fmtOf(T);
    const e: i64 = @as(i64, f.bias) + @as(i64, @intCast(below(2 * spread + 1))) - spread;
    return mk(T, below(2) == 1, @intCast(e), nextU128());
}

const Std = struct {
    fn minSub(comptime T: type) Bits(T) {
        return mk(T, false, 0, 1);
    }
    fn maxSub(comptime T: type) Bits(T) {
        return mk(T, false, 0, ~@as(u128, 0));
    }
    fn minNorm(comptime T: type) Bits(T) {
        return mk(T, false, 1, 0);
    }
    fn one(comptime T: type) Bits(T) {
        return mk(T, false, @intCast((comptime fmtOf(T)).bias), 0);
    }
    /// 2^k (normal range)
    fn pow2(comptime T: type, k: i32) Bits(T) {
        return mk(T, false, @intCast((comptime fmtOf(T)).bias + k), 0);
    }
    fn max(comptime T: type) Bits(T) {
        return mk(T, false, emaxField(T) - 1, ~@as(u128, 0));
    }
    fn qnan(comptime T: type, negative: bool, payload: u128) Bits(T) {
        return mk(T, negative, emaxField(T), (@as(u128, 1) << ((comptime fmtOf(T)).p - 2)) | payload);
    }
    fn snan(comptime T: type, negative: bool, payload: u128) Bits(T) {
        std.debug.assert(payload != 0);
        return mk(T, negative, emaxField(T), payload);
    }
    fn neg(comptime T: type, b: Bits(T)) Bits(T) {
        return b ^ signMask(T);
    }
    /// exact value m * 2^e (must be representable)
    fn exact(comptime T: type, neg_: bool, m: u128, e: i64) Bits(T) {
        return roundTo(T, neg_, big(m), e, false);
    }
};

/// 14 operands crossed with each other for + - * / and comparisons.
fn arithSet(comptime T: type) []const Bits(T) {
    const f = comptime fmtOf(T);
    const list = gpa.alloc(Bits(T), 14) catch oom();
    list[0] = 0;
    list[1] = signMask(T);
    list[2] = Std.minSub(T);
    list[3] = Std.neg(T, Std.maxSub(T));
    list[4] = Std.minNorm(T);
    list[5] = Std.one(T);
    list[6] = Std.neg(T, Std.one(T));
    list[7] = Std.exact(T, false, 3, 0);
    list[8] = mk(T, false, @intCast(f.bias - 4), 0x5555_5555_5555_5555_5555_5555_5555_5555); // ~0.083
    list[9] = Std.max(T);
    list[10] = Std.neg(T, Std.max(T));
    list[11] = infBits(T, false);
    list[12] = infBits(T, true);
    list[13] = Std.qnan(T, false, 5);
    return list;
}

// ---------------------------------------------------------------------------
// Run-side helpers
// ---------------------------------------------------------------------------

fn zigArith(comptime T: type, op: Op, ab: Bits(T), bb: Bits(T)) Bits(T) {
    const a = fromBits(T, ab);
    const b = fromBits(T, bb);
    return toBits(T, switch (op) {
        .add => a + b,
        .sub => a - b,
        .mul => a * b,
        .div => a / b,
    });
}

fn zigCast(comptime S: type, comptime D: type, sb: Bits(S)) Bits(D) {
    const x = fromBits(S, sb);
    const y: D = @floatCast(x);
    return toBits(D, y);
}

// ---------------------------------------------------------------------------
// Observed NaN rules of the canonical reference build (-fllvm -mcpu=baseline).
// These are what README.md documents; every NaN result is checked against them.
// ---------------------------------------------------------------------------

/// The vectors are only checked (and only meant to be committed) for the
/// canonical configuration; other configurations are generated for diffing.
const canonical = builtin.zig_backend == .stage2_llvm and std.mem.eql(u8, builtin.cpu.model.name, "x86_64");

/// Result of an invalid operation (0/0, inf-inf, 0*inf, inf/inf).
fn modelDefaultNan(comptime T: type) Bits(T) {
    return switch (T) {
        f16 => 0xFE00, // f32 SSE default NaN, narrowed by __truncsfhf2
        f32 => 0xFFC0_0000, // SSE
        f64 => 0xFFF8_0000_0000_0000, // SSE
        f80 => 0xFFFF_C000_0000_0000_0000, // x87 real indefinite
        f128 => 0x7FFF_8000_0000_0000_0000_0000_0000_0000, // compiler-rt
        else => unreachable,
    };
}

fn quietNan(comptime T: type, b: Bits(T)) Bits(T) {
    return b | quietBit(T);
}

/// f80 significand (explicit integer bit included) for the x87 two-NaN rule.
fn f80Significand(b: u80) u64 {
    return @truncate(b);
}

/// NaN result of a op b when at least one operand is NaN or the operation is
/// invalid (refArith returned .nan).
fn modelArithNan(comptime T: type, op: Op, ab: Bits(T), bb: Bits(T)) Bits(T) {
    const an = isNanBits(T, ab);
    const bn = isNanBits(T, bb);
    if (!an and !bn) return modelDefaultNan(T);
    if (T == f80 and an and bn) {
        // x87: a quiet NaN beats a signaling one; otherwise the NaN with the
        // larger significand wins; on equal significands the positive one wins
        // (either order). The winner is returned quieted.
        const qa = (ab & quietBit(T)) != 0;
        const qb = (bb & quietBit(T)) != 0;
        if (qa != qb) return quietNan(T, if (qa) ab else bb);
        const sa = f80Significand(ab);
        const sb = f80Significand(bb);
        if (sa != sb) return quietNan(T, if (sb > sa) bb else ab);
        return quietNan(T, if ((ab & signMask(T)) == 0) ab else bb);
    }
    if (an) return quietNan(T, ab);
    // compiler-rt __subtf3 is __addtf3(a, -b): a NaN rhs comes back negated.
    if (T == f128 and op == .sub) return quietNan(T, bb ^ signMask(T));
    return quietNan(T, bb);
}

/// NaN result of @floatCast(S -> D).
fn modelCastNan(comptime S: type, comptime D: type, sb: Bits(S)) Bits(D) {
    const d = decompose(S, sb);
    const fs = comptime fmtOf(S);
    const fd = comptime fmtOf(D);
    const shifted: u128 = if (fd.p >= fs.p) d.sig << (fd.p - fs.p) else d.sig >> (fs.p - fd.p);
    var r: Bits(D) = mk(D, d.neg, emaxField(D), shifted);
    const quiets = if (fd.p < fs.p)
        !(S == f128 and D == f80) // __trunctfxf2 keeps the quiet bit as is
    else
        (S == f16 and D == f64) or (S == f32 and D == f64) or (D == f80 and S != f16);
    if (quiets) r |= quietBit(D);
    // A NaN must stay a NaN (see the __trunctfxf2 crt-bug in README.md).
    if (!isNanBits(D, r)) r |= quietBit(D);
    return r;
}

// ---------------------------------------------------------------------------
// NaN-rule tallies (stage-0 contract in src/c3/float_value.c3), stderr only
// ---------------------------------------------------------------------------

const Tally = struct { agree: usize = 0, disagree: usize = 0 };
var nan_tally: [5][4]Tally = @splat(@splat(.{}));
var cast_tally: [5][5]Tally = @splat(@splat(.{}));

fn widthIndex(comptime T: type) usize {
    inline for (Widths, 0..) |W, i| if (W == T) return i;
    unreachable;
}

fn contractDefaultNan(comptime T: type) Bits(T) {
    return switch (T) {
        f16 => 0xFE00,
        f32 => 0xFFC0_0000,
        f64 => 0xFFF8_0000_0000_0000,
        f80 => 0xFFFF_C000_0000_0000_0000,
        f128 => 0x7FFF_8000_0000_0000_0000_0000_0000_0000,
        else => unreachable,
    };
}

fn contractArithNan(comptime T: type, ab: Bits(T), bb: Bits(T)) Bits(T) {
    const an = isNanBits(T, ab);
    const bn = isNanBits(T, bb);
    if (an) return ab | quietBit(T);
    if (bn) return bb | quietBit(T);
    return contractDefaultNan(T);
}

fn tallyArith(comptime T: type, op: Op, ab: Bits(T), bb: Bits(T), got: Bits(T)) void {
    if (!isNanBits(T, got)) return;
    if (decompose(T, ab).kind == .noncanon or decompose(T, bb).kind == .noncanon) return;
    const want = contractArithNan(T, ab, bb);
    const t = &nan_tally[widthIndex(T)][@backingInt(op)];
    if (want == got) t.agree += 1 else {
        t.disagree += 1;
        if (t.disagree <= 3) std.debug.print("nan-rule {s} {s}: {x} {x} -> {x} (contract {x})\n", .{ @typeName(T), op.name(), ab, bb, got, want });
    }
}

fn tallyCast(comptime S: type, comptime D: type, sb: Bits(S), got: Bits(D)) void {
    const d = decompose(S, sb);
    if (d.kind != .nan) return;
    const fs = comptime fmtOf(S);
    const fd = comptime fmtOf(D);
    // contract: sign kept, payload aligned at the top; narrowing quiets; widening quiets
    // only on SSE f32->f64 and x87 any->f80.
    const payload: u128 = d.sig; // stored fraction incl. quiet bit
    const shifted: u128 = if (fd.p >= fs.p) payload << (fd.p - fs.p) else payload >> (fs.p - fd.p);
    var want: Bits(D) = mk(D, d.neg, emaxField(D), shifted);
    const quiets = fd.p < fs.p or (S == f32 and D == f64) or D == f80;
    if (quiets) want |= quietBit(D);
    const t = &cast_tally[widthIndex(S)][widthIndex(D)];
    if (want == got) t.agree += 1 else {
        t.disagree += 1;
        if (t.disagree <= 2) std.debug.print("nan-cast {s}->{s}: {x} -> {x} (contract {x})\n", .{ @typeName(S), @typeName(D), sb, got, want });
    }
}

// ---------------------------------------------------------------------------
// Generators
// ---------------------------------------------------------------------------

/// Model result of a op b: bits, or null when there is no model (f80
/// non-canonical operands).
fn modelArith(comptime T: type, op: Op, a: Bits(T), b: Bits(T)) ?Bits(T) {
    return switch (refArith(T, op, a, b)) {
        .skip => null,
        .nan => modelArithNan(T, op, a, b),
        .bits => |r| @intCast(r),
    };
}

/// Paths that run in Zig's compiler_rt soft-float code on x86_64 (as opposed to
/// SSE / x87 hardware). Only these may disagree with the model as a crt-bug.
fn crtArith(comptime T: type) bool {
    return T == f128 or T == f16;
}
fn crtCast(comptime S: type, comptime D: type) bool {
    return S == f16 or D == f16 or S == f128 or D == f128;
}

var lib_bugs: usize = 0;

/// Pick the vector value and provenance for a run result `got` and a model
/// result. A disagreement on a compiler_rt path is recorded as a crt-bug (the
/// vector keeps the model value, a comment keeps Zig's output); anywhere else it
/// is a generation error.
fn settle(o: *Out, comptime T: type, got: Bits(T), model: ?Bits(T), crt: bool, comptime what: []const u8, args: anytype) struct { Bits(T), []const u8 } {
    const m = model orelse return .{ got, PROV_RUN };
    if (m == got) return .{ got, PROV_EXACT };
    if (crt) {
        lib_bugs += 1;
        const digits = comptime std.fmt.comptimePrint("{d}", .{(@bitSizeOf(T) + 3) / 4});
        o.comment("lib-bug: zig-0.17.0 gave 0x{x:0>" ++ digits ++ "}; the vector holds the model value", .{got});
        return .{ m, PROV_LIB };
    }
    mismatch(what ++ ": zig {x}, model {x}", args ++ .{ got, m });
    return .{ got, PROV_EXACT };
}

fn emitArith(o: *Out, comptime T: type, op: Op, a: Bits(T), b: Bits(T)) void {
    const got = zigArith(T, op, a, b);
    tallyArith(T, op, a, b, got);
    const val, const prov = settle(o, T, got, modelArith(T, op, a, b), crtArith(T), "{s} {s} {x} {x}", .{ op.name(), @typeName(T), a, b });
    o.word(op.name());
    o.ty(T);
    o.f(T, a);
    o.f(T, b);
    o.eq();
    o.f(T, val);
    o.end(prov);
}

fn genArith(o: *Out) void {
    header(o, "Real float + - * / at every width (Value.add/sub/mul/div float branch)", "add sub mul div");
    inline for (Widths) |T| {
        const f = comptime fmtOf(T);
        const ops = [_]Op{ .add, .sub, .mul, .div };
        o.comment("--- {s}: special operand cross product", .{@typeName(T)});
        const set = arithSet(T);
        for (ops) |op| for (set) |a| for (set) |b| emitArith(o, T, op, a, b);

        o.comment("--- {s}: rounding ties (round half to even), add/sub", .{@typeName(T)});
        const half_ulp_of_one = Std.pow2(T, -@as(i32, @intCast(f.p))); // 2^-p
        for (0..8) |i| {
            var a = mk(T, false, @intCast(f.bias), nextU128());
            if (i % 2 == 0) a &= ~@as(Bits(T), 1) else a |= 1; // even / odd significand
            emitArith(o, T, .add, a, half_ulp_of_one); // exact tie
            emitArith(o, T, .sub, a, Std.neg(T, half_ulp_of_one));
            emitArith(o, T, .add, a, half_ulp_of_one + 1); // just above the tie
            emitArith(o, T, .add, a, half_ulp_of_one - 1); // just below (largest below)
            emitArith(o, T, .sub, a, half_ulp_of_one); // tie on the way down
            emitArith(o, T, .add, Std.neg(T, a), Std.neg(T, half_ulp_of_one));
        }
        o.comment("--- {s}: rounding ties, mul: (1+2^-s)(1+2^-t) with s+t = p", .{@typeName(T)});
        var s: u32 = 1;
        while (s < f.p) : (s += if (f.p > 40) 7 else 1) {
            const t = f.p - s;
            const a = Std.exact(T, false, (@as(u128, 1) << @intCast(s)) + 1, -@as(i64, s));
            const b = Std.exact(T, false, (@as(u128, 1) << @intCast(t)) + 1, -@as(i64, t));
            emitArith(o, T, .mul, a, b);
            emitArith(o, T, .mul, Std.neg(T, a), b);
            const b2 = Std.exact(T, false, (@as(u128, 3) << @intCast(t - 1)) + 1, -@as(i64, t)); // non-tie neighbour
            emitArith(o, T, .mul, a, b2);
        }
        o.comment("--- {s}: subnormal results and ties", .{@typeName(T)});
        const two = Std.pow2(T, 1);
        const half = Std.pow2(T, -1);
        const quarter3 = Std.exact(T, false, 3, -2);
        const three = Std.exact(T, false, 3, 0);
        const sub_cases = [_]Bits(T){
            Std.minSub(T),                 Std.minSub(T) * 3,
            Std.minSub(T) * 5,             Std.maxSub(T),
            Std.minNorm(T),                Std.minNorm(T) + 1,
            Std.neg(T, Std.minSub(T) * 7), Std.neg(T, Std.minNorm(T)),
        };
        for (sub_cases) |a| {
            emitArith(o, T, .div, a, two);
            emitArith(o, T, .mul, a, half);
            emitArith(o, T, .mul, a, quarter3);
            emitArith(o, T, .div, a, three);
            emitArith(o, T, .sub, a, Std.minSub(T));
            emitArith(o, T, .add, a, Std.neg(T, Std.minNorm(T)));
        }
        emitArith(o, T, .mul, Std.minNorm(T), Std.minNorm(T)); // underflow to +0
        emitArith(o, T, .mul, Std.neg(T, Std.minNorm(T)), Std.minNorm(T)); // to -0
        emitArith(o, T, .div, Std.one(T), Std.max(T));
        emitArith(o, T, .div, Std.minSub(T), Std.max(T));
        emitArith(o, T, .div, Std.minNorm(T), Std.pow2(T, @intCast(f.p - 1)));
        emitArith(o, T, .div, Std.minNorm(T), Std.pow2(T, @intCast(f.p)));

        o.comment("--- {s}: overflow boundary", .{@typeName(T)});
        const max = Std.max(T);
        const hulp_max = Std.pow2(T, f.bias - @as(i32, @intCast(f.p))); // half ulp of max
        emitArith(o, T, .add, max, max);
        emitArith(o, T, .mul, max, two);
        emitArith(o, T, .add, max, hulp_max); // tie -> odd max rounds up -> inf
        emitArith(o, T, .add, max, Std.pow2(T, f.bias - @as(i32, @intCast(f.p)) - 1));
        emitArith(o, T, .sub, Std.neg(T, max), hulp_max);
        emitArith(o, T, .div, max, half);
        emitArith(o, T, .div, max, Std.minSub(T));
        emitArith(o, T, .mul, max, Std.neg(T, max));
        emitArith(o, T, .div, Std.one(T), Std.minSub(T));
        emitArith(o, T, .div, Std.one(T), 0);
        emitArith(o, T, .div, Std.neg(T, Std.one(T)), 0);
        emitArith(o, T, .div, Std.one(T), signMask(T));

        o.comment("--- {s}: signed zero results", .{@typeName(T)});
        emitArith(o, T, .sub, Std.one(T), Std.one(T));
        emitArith(o, T, .add, Std.neg(T, Std.one(T)), Std.one(T));
        emitArith(o, T, .sub, signMask(T), 0);
        emitArith(o, T, .sub, signMask(T), signMask(T));
        emitArith(o, T, .mul, signMask(T), Std.neg(T, Std.one(T)));
        emitArith(o, T, .div, signMask(T), infBits(T, false));

        o.comment("--- {s}: pseudo-random operands", .{@typeName(T)});
        for (0..40) |_| {
            const a = rndBits(T);
            const b = rndBits(T);
            for (ops) |op| emitArith(o, T, op, a, b);
        }
        for (0..40) |_| {
            const spread: u32 = if (T == f16) 6 else 30;
            const a = rndNormal(T, spread);
            const b = rndNormal(T, spread);
            for (ops) |op| emitArith(o, T, op, a, b);
        }
        o.comment("--- {s}: near cancellation", .{@typeName(T)});
        for (0..20) |_| {
            const a = rndNormal(T, 4);
            const delta: Bits(T) = @intCast(below(16) + 1);
            const b = if (below(2) == 0) a + delta else a - delta;
            emitArith(o, T, .sub, a, b);
            emitArith(o, T, .add, a, Std.neg(T, b));
        }
    }
}

const nan_ops = [_]Op{ .add, .sub, .mul, .div };

fn genNan(o: *Out) void {
    header(o, "NaN results: default NaN, NaN propagation, f80 encodings, NaN casts", "add sub mul div cast");
    inline for (Widths) |T| {
        const f = comptime fmtOf(T);
        const one = Std.one(T);
        const top_payload: u128 = @as(u128, 1) << (f.p - 3); // highest non-quiet payload bit
        const nans = [_]Bits(T){
            Std.qnan(T, false, 1),
            Std.qnan(T, true, 2),
            Std.qnan(T, false, top_payload | 3),
            Std.snan(T, false, 1),
            Std.snan(T, true, top_payload | 6),
        };
        o.comment("--- {s}: invalid operations (default NaN)", .{@typeName(T)});
        const inf_ = infBits(T, false);
        const ninf = infBits(T, true);
        emitArith(o, T, .div, 0, 0);
        emitArith(o, T, .div, signMask(T), 0);
        emitArith(o, T, .div, inf_, inf_);
        emitArith(o, T, .div, ninf, inf_);
        emitArith(o, T, .sub, inf_, inf_);
        emitArith(o, T, .add, inf_, ninf);
        emitArith(o, T, .add, ninf, inf_);
        emitArith(o, T, .mul, 0, inf_);
        emitArith(o, T, .mul, ninf, 0);
        emitArith(o, T, .mul, signMask(T), ninf);
        o.comment("--- {s}: one NaN operand", .{@typeName(T)});
        for (nans) |n| for (nan_ops) |op| {
            emitArith(o, T, op, n, one);
            emitArith(o, T, op, one, n);
            emitArith(o, T, op, n, inf_);
            emitArith(o, T, op, 0, n);
        };
        o.comment("--- {s}: two NaN operands (both orders)", .{@typeName(T)});
        for (nans, 0..) |n1, i| for (nans[i + 1 ..]) |n2| for (nan_ops) |op| {
            emitArith(o, T, op, n1, n2);
            emitArith(o, T, op, n2, n1);
        };
        o.comment("--- {s}: two NaNs with equal significands / two signaling NaNs", .{@typeName(T)});
        const pairs = [_][2]Bits(T){
            .{ Std.qnan(T, false, 5), Std.qnan(T, true, 5) },
            .{ Std.snan(T, false, 5), Std.snan(T, true, 5) },
            .{ Std.snan(T, false, 5), Std.snan(T, true, top_payload) },
            .{ Std.snan(T, true, 1), Std.qnan(T, false, 0) },
        };
        for (pairs) |pr| for (nan_ops) |op| {
            emitArith(o, T, op, pr[0], pr[1]);
            emitArith(o, T, op, pr[1], pr[0]);
        };
        if (T == f80) {
            o.comment("--- f80: non-canonical encodings (pseudo-NaN, pseudo-inf, unnormal, pseudo-denormal)", .{});
            const nc = [_]u80{
                0x7fff_0000000000000001, // pseudo-NaN
                0x7fff_4000000000000000, // pseudo-NaN (quiet bit, no integer bit)
                0x7fff_0000000000000000, // pseudo-infinity
                0xffff_0000000000000000, // negative pseudo-infinity
                0x3fff_4000000000000000, // unnormal (0.5 without integer bit)
                0x0000_8000000000000000, // pseudo-denormal (2^-16382)
                0x8000_c000000000000000, // negative pseudo-denormal
            };
            for (nc) |n| for (nan_ops) |op| {
                emitArith(o, T, op, n, one);
                emitArith(o, T, op, one, n);
            };
            for (nc) |n| emitArith(o, T, .add, n, n);
        }
        o.comment("--- {s}: NaN casts to every other width", .{@typeName(T)});
        inline for (Widths) |D| {
            if (D != T) {
                for (nans) |n| emitCast(o, T, D, n);
                emitCast(o, T, D, Std.qnan(T, false, (@as(u128, 1) << (f.p - 2)) - 1)); // full payload
                emitCast(o, T, D, Std.snan(T, true, (@as(u128, 1) << (f.p - 2)) - 1));
                if (T == f80) {
                    emitCast(o, T, D, 0x7fff_0000000000000001);
                    emitCast(o, T, D, 0x7fff_0000000000000000);
                    emitCast(o, T, D, 0x3fff_4000000000000000);
                    emitCast(o, T, D, 0x0000_8000000000000000);
                }
            }
        }
    }
}

fn emitCast(o: *Out, comptime S: type, comptime D: type, sb: Bits(S)) void {
    const got = zigCast(S, D, sb);
    tallyCast(S, D, sb, got);
    const val, const prov = settle(o, D, got, modelCast(S, D, sb), crtCast(S, D), "cast {s}->{s} {x}", .{ @typeName(S), @typeName(D), sb });
    o.word("cast");
    o.ty(S);
    o.ty(D);
    o.f(S, sb);
    o.eq();
    o.f(D, val);
    o.end(prov);
}

fn genCast(o: *Out) void {
    header(o, "@floatCast between every pair of widths (Value.floatCast / toFloat of a float key)", "cast");
    inline for (Widths) |S| inline for (Widths) |D| if (S != D) {
        const fs = comptime fmtOf(S);
        const fd = comptime fmtOf(D);
        o.comment("--- {s} -> {s}", .{ @typeName(S), @typeName(D) });
        const specials = [_]Bits(S){
            0,                     signMask(S),
            Std.minSub(S),         Std.neg(S, Std.minSub(S)),
            Std.maxSub(S),         Std.minNorm(S),
            Std.one(S),            Std.neg(S, Std.exact(S, false, 3, -1)),
            Std.max(S),            Std.neg(S, Std.max(S)),
            infBits(S, false),     infBits(S, true),
            Std.qnan(S, false, 0), Std.qnan(S, true, 9),
        };
        for (specials) |x| emitCast(o, S, D, x);
        for (0..24) |_| emitCast(o, S, D, rndBits(S));
        for (0..12) |_| emitCast(o, S, D, rndNormal(S, 12));
        if (fd.p < fs.p) {
            // ties and near-ties in the destination's normal range
            const sh: u7 = @intCast(fs.p - fd.p);
            for (0..10) |i| {
                const ue: i32 = @as(i32, @intCast(below(20))) - 10;
                var dm: u128 = nextU128() & ((@as(u128, 1) << @intCast(fd.p - 1)) - 1);
                if (i % 2 == 0) dm &= ~@as(u128, 1) else dm |= 1;
                const base = dm << sh;
                const tie = @as(u128, 1) << (sh - 1);
                const biased: u32 = @intCast(fs.bias + ue);
                const neg = i % 4 >= 2;
                emitCast(o, S, D, mk(S, neg, biased, base | tie));
                emitCast(o, S, D, mk(S, neg, biased, base | tie | 1));
                emitCast(o, S, D, mk(S, neg, biased, base | (tie - 1)));
            }
            // subnormal destination: (2k+1)/2 * minsub_D, k even and odd, and neighbours
            const d_q: i64 = 1 - @as(i64, fd.bias) - (fd.p - 1); // exponent of D's min subnormal
            for ([_]u128{ 0, 1, 2, 3, 100, 101, (@as(u128, 1) << @intCast(fd.p - 1)) - 1 }) |k| {
                const v = 2 * k + 1;
                emitCast(o, S, D, Std.exact(S, false, v, d_q - 1));
                emitCast(o, S, D, Std.exact(S, true, v, d_q - 1));
                emitCast(o, S, D, Std.exact(S, false, (v << 8) + 1, d_q - 9));
                emitCast(o, S, D, Std.exact(S, false, (v << 8) - 1, d_q - 9));
            }
            // underflow to zero boundary
            emitCast(o, S, D, Std.exact(S, false, 1, d_q - 2));
            emitCast(o, S, D, Std.exact(S, false, 3, d_q - 3));
            // largest subnormal / smallest normal of D, via rounding
            emitCast(o, S, D, Std.exact(S, false, (@as(u128, 1) << @intCast(fd.p)) - 1, d_q - 1));
            // overflow boundary: D max, D max + half ulp (tie -> inf), just below
            const d_maxe: i64 = @as(i64, fd.bias) - (fd.p - 1);
            const dmax_m = (@as(u128, 1) << @intCast(fd.p)) - 1;
            emitCast(o, S, D, Std.exact(S, false, dmax_m, d_maxe));
            emitCast(o, S, D, Std.exact(S, false, 2 * dmax_m + 1, d_maxe - 1));
            emitCast(o, S, D, Std.exact(S, true, 2 * dmax_m + 1, d_maxe - 1));
            emitCast(o, S, D, Std.exact(S, false, (2 * dmax_m + 1) * 256 - 1, d_maxe - 9));
            emitCast(o, S, D, Std.exact(S, false, 1, @as(i64, fd.bias) + 1));
        }
    };
}

fn genIntFloat(o: *Out) void {
    header(o, "int -> float: @floatFromInt of u64/i64, Value.bigIntToFloat, Value.intToFloat", "from_u64 from_i64 big_to_f128 int_to_float");
    const u64s = [_]u64{
        0,                     1,                     2,                     3,
        7,                     2047,                  2048,                  2049,
        4097,                  65504,                 65519,                 65520,
        65535,                 65536,                 (1 << 24) + 1,         (1 << 24) + 3,
        (1 << 25) + 2,         0x7fff_ffff,           0xffff_ffff,           1 << 32,
        (1 << 53) + 1,         (1 << 53) + 3,         (1 << 54) + 2,         (1 << 54) + 6,
        (1 << 63) - 1,         1 << 63,               (1 << 63) + 1024,      (1 << 63) + 1025,
        0xffff_ffff_ffff_fbff, 0xffff_ffff_ffff_fc00, 0xffff_ffff_ffff_ffff, 0xffff_ff7f_ffff_ffff,
        0xffff_ff80_0000_0000, 0xffff_ff80_0000_0001,
    };
    inline for (Widths) |T| {
        o.comment("--- @floatFromInt(u64) -> {s}", .{@typeName(T)});
        for (u64s) |x| emitFromInt(o, T, u64, x);
        for (0..10) |_| emitFromInt(o, T, u64, nextU64() >> @intCast(below(64)));
        o.comment("--- @floatFromInt(i64) -> {s}", .{@typeName(T)});
        for (u64s) |x| {
            const s: i64 = @bitCast(x);
            emitFromInt(o, T, i64, s);
            if (s != std.math.minInt(i64)) emitFromInt(o, T, i64, -s);
        }
    }

    o.comment("--- bigIntToFloat (one fused @mulAdd(f128, 2^64, acc, limb) rounding per limb)", .{});
    var bigs: std.ArrayList(Managed) = .empty;
    const add = struct {
        fn f(l: *std.ArrayList(Managed), m: Managed) void {
            l.append(gpa, m) catch oom();
            l.append(gpa, bigNeg(m)) catch oom();
        }
    }.f;
    // exactly representable, two limbs
    add(&bigs, big(@as(u128, 1) << 64));
    add(&bigs, big((@as(u128, 1) << 64) + 1));
    add(&bigs, big(@as(u128, std.math.maxInt(u64)) + 2));
    add(&bigs, big((@as(u128, 1) << 112) + 1));
    add(&bigs, big((@as(u128, 1) << 113) + 1)); // tie at f128 -> even
    add(&bigs, big((@as(u128, 1) << 113) + 3)); // tie -> up
    add(&bigs, big(std.math.maxInt(u128)));
    add(&bigs, big(@as(u128, std.math.maxInt(i64)) + 1));
    // single-step rounding (2 limbs) exceeding 113 bits
    add(&bigs, big((@as(u128, 1) << 127) + (1 << 14) + 1));
    add(&bigs, big((@as(u128, 1) << 127) + (1 << 14)));
    // three limbs where the per-limb roundings differ from one rounding
    add(&bigs, bigAdd(bigAdd(bigPow2(191), bigPow2(78)), big(1)));
    add(&bigs, bigAdd(bigAdd(bigPow2(191), bigPow2(78)), bigPow2(63)));
    add(&bigs, bigAdd(bigAdd(bigPow2(191), bigSub(bigPow2(79), bigPow2(64))), big(1)));
    // double rounding into each destination via the f128 hub
    add(&bigs, bigAdd(bigAdd(bigPow2(114), bigPow2(61)), big(1))); // f64 tie after f128
    add(&bigs, bigAdd(bigAdd(bigPow2(120), bigPow2(96)), big(1))); // f32 tie after f128
    add(&bigs, bigAdd(bigAdd(bigPow2(150), bigPow2(86)), big(1))); // f80 tie after f128
    add(&bigs, bigAdd(bigPow2(150), bigAdd(bigPow2(86), bigPow2(20))));
    // large magnitudes, f128 overflow
    add(&bigs, bigPow2(200));
    add(&bigs, bigSub(bigPow2(1000), big(1)));
    add(&bigs, bigSub(bigPow2(16384), big(1)));
    add(&bigs, bigPow2(16384));
    add(&bigs, bigSub(bigPow2(16384), bigPow2(16384 - 113))); // f128 max
    add(&bigs, bigSub(bigPow2(16384), bigPow2(16384 - 114))); // max + half ulp
    add(&bigs, bigSub(bigPow2(16384), bigPow2(16384 - 115)));
    add(&bigs, bigPow2(1100)); // beyond f64 range
    add(&bigs, bigSub(bigPow2(1024), bigPow2(1024 - 54))); // f64 max + half ulp
    add(&bigs, bigSub(bigPow2(128), bigPow2(128 - 25))); // f32 max + half ulp
    for (0..16) |_| {
        const nbits: usize = 65 + below(300);
        var m = big(0);
        var left = nbits;
        while (left > 0) {
            const take = @min(left, 64);
            m = bigAdd(bigShl(m, take), big(nextU64() >> @intCast(64 - take)));
            left -= take;
        }
        m = bigAdd(m, bigPow2(nbits - 1));
        add(&bigs, m);
    }
    for (bigs.items) |m| {
        const c = m.toConst();
        const got = toBits(f128, bigIntToFloat(c.limbs, c.positive));
        const model = modelBigIntToFloat(c.limbs, c.positive);
        const correct = roundSigned(f128, m, 0);
        if (got != model) mismatch("big_to_f128 {f}: zig {x} model {x}", .{ m, got, model });
        o.word("big_to_f128");
        o.int(c);
        o.eq();
        o.f(f128, got);
        o.end(if (got == correct) PROV_EXACT else PROV_DBL);
    }

    inline for (Widths) |T| {
        o.comment("--- Value.intToFloat / toFloat({s}) of an interned int", .{@typeName(T)});
        var vals: std.ArrayList(Managed) = .empty;
        for ([_]i128{ 0, 1, -1, 2, 3, 2049, -2049, 65504, 65520, 0x7fff_ffff, -0x8000_0000, 0xffff_ffff, -0x8000_0001, 0x1_0000_0000, (1 << 53) + 1, -((1 << 53) + 1), (1 << 63) + 1025, std.math.maxInt(i64), std.math.minInt(i64), (1 << 64) - 1, -(1 << 64) + 1 }) |x|
            vals.append(gpa, big(x)) catch oom();
        // Huge magnitudes only matter for the f128 hub; elsewhere they are just inf.
        for (bigs.items) |m| if (T == f128 or m.bitCountAbs() <= 1200) vals.append(gpa, m) catch oom();
        for (vals.items) |m| {
            const got = toBits(T, intToFloatPort(T, m));
            const c = m.toConst();
            const repr = internedRepr(m);
            var model: Bits(T) = undefined;
            if (repr == .big_int) {
                const hub = modelBigIntToFloat(c.limbs, c.positive);
                model = switch (refCast(f128, T, hub)) {
                    .bits => |b| @intCast(b),
                    else => unreachable,
                };
            } else model = roundSigned(T, m, 0);
            const correct = roundSigned(T, m, 0);
            if (got != model) mismatch("int_to_float {s} {f}: zig {x} model {x}", .{ @typeName(T), m, got, model });
            o.word("int_to_float");
            o.ty(T);
            o.int(c);
            o.eq();
            o.f(T, got);
            o.end(if (got == correct) PROV_EXACT else PROV_DBL);
        }
    }
}

fn emitFromInt(o: *Out, comptime T: type, comptime I: type, x: I) void {
    const got = toBits(T, @as(T, @floatFromInt(launder(I, x))));
    const want = roundSigned(T, big(x), 0);
    if (got != want) mismatch("from_int {s} {d}: zig {x} model {x}", .{ @typeName(T), x, got, want });
    o.word(if (I == u64) "from_u64" else "from_i64");
    o.ty(T);
    o.int(big(x).toConst());
    o.eq();
    o.f(T, got);
    o.end(PROV_EXACT);
}

fn genFloatToInt(o: *Out) void {
    header(o, "Value.floatToInt: value = toFloat(f128) of the operand, then setFloat(.trunc)", "float_to_int");
    const dests = [_]Dest{
        .bool,
        .{ .int = .{ .sign = .unsigned, .bits = 1 } },
        .{ .int = .{ .sign = .signed, .bits = 2 } },
        .{ .int = .{ .sign = .signed, .bits = 8 } },
        .{ .int = .{ .sign = .unsigned, .bits = 8 } },
        .{ .int = .{ .sign = .signed, .bits = 16 } },
        .{ .int = .{ .sign = .unsigned, .bits = 16 } },
        .{ .int = .{ .sign = .signed, .bits = 32 } },
        .{ .int = .{ .sign = .unsigned, .bits = 32 } },
        .{ .int = .{ .sign = .signed, .bits = 64 } },
        .{ .int = .{ .sign = .unsigned, .bits = 64 } },
        .{ .int = .{ .sign = .signed, .bits = 65 } },
        .{ .int = .{ .sign = .signed, .bits = 128 } },
        .{ .int = .{ .sign = .unsigned, .bits = 128 } },
        .{ .int = .{ .sign = .unsigned, .bits = 200 } },
    };
    inline for (Widths) |T| {
        const f = comptime fmtOf(T);
        o.comment("--- source {s}", .{@typeName(T)});
        var vals: std.ArrayList(Bits(T)) = .empty;
        const app = struct {
            fn push(l: *std.ArrayList(Bits(T)), b: Bits(T)) void {
                l.append(gpa, b) catch oom();
            }
        }.push;
        for ([_]Bits(T){ 0, signMask(T), Std.minSub(T), Std.neg(T, Std.minSub(T)), Std.max(T), Std.neg(T, Std.max(T)), infBits(T, false), infBits(T, true), Std.qnan(T, false, 0), Std.qnan(T, true, 3) }) |b| app(&vals, b);
        // m/2^k values around small integers and type limits
        const pairs = [_]struct { m: i64, e: i64 }{
            .{ .m = 1, .e = -1 },  .{ .m = -1, .e = -1 },   .{ .m = 3, .e = -2 },   .{ .m = 1, .e = 0 },
            .{ .m = -1, .e = 0 },  .{ .m = 3, .e = -1 },    .{ .m = -3, .e = -1 },  .{ .m = 2, .e = 0 },
            .{ .m = -2, .e = 0 },  .{ .m = 255, .e = -1 },  .{ .m = 127, .e = 0 },  .{ .m = 255, .e = 0 },
            .{ .m = 256, .e = 0 }, .{ .m = -257, .e = -1 }, .{ .m = -128, .e = 0 }, .{ .m = -129, .e = 0 },
            .{ .m = 1, .e = 15 },  .{ .m = 65535, .e = 0 }, .{ .m = -1, .e = 15 },  .{ .m = 1, .e = 31 },
            .{ .m = -1, .e = 31 }, .{ .m = 1, .e = 32 },    .{ .m = 3, .e = 31 },   .{ .m = 1, .e = 63 },
            .{ .m = -1, .e = 63 }, .{ .m = 1, .e = 64 },    .{ .m = 1, .e = 127 },  .{ .m = -1, .e = 127 },
            .{ .m = 1, .e = 128 }, .{ .m = 1, .e = 199 },   .{ .m = 1, .e = 200 },  .{ .m = 5, .e = 1000 },
            .{ .m = 1, .e = -20 },
        };
        for (pairs) |pr| {
            const neg = pr.m < 0;
            const mag: u128 = @abs(pr.m);
            // only representable values (skip ones that would overflow/round)
            const L: i64 = 128 - @as(i64, @clz(mag));
            if (L > f.p) continue;
            if (L - 1 + pr.e > f.bias or L - 1 + pr.e < 1 - @as(i64, f.bias) - (f.p - 1)) continue;
            app(&vals, Std.exact(T, neg, mag, pr.e));
        }
        for (0..6) |_| app(&vals, rndNormal(T, if (T == f16) 14 else 40));
        for (vals.items) |b| for (dests) |d| {
            const fv: f128 = @floatCast(fromBits(T, b));
            const res = floatToIntPort(fv, d);
            const model = modelFloatToInt(toBits(f128, fv), d);
            const same_val = if (res.val) |v| (if (model.val) |mv| v.eql(mv) else false) else model.val == null;
            if (!same_val or res.kind != model.kind) mismatch("float_to_int {s} {x}: zig {s} model {s}", .{ @typeName(T), b, @tagName(res.kind), @tagName(model.kind) });
            o.word("float_to_int");
            o.ty(T);
            d.write(o);
            o.f(T, b);
            o.eq();
            if (res.val) |v| o.int(v) else o.word("none");
            o.word(@tagName(res.kind));
            o.end(PROV_EXACT);
        };
    }
}

fn cmpWord(buf: *[6]u8, comptime T: type, a: T, b: T) []const u8 {
    const ops = [_]math.CompareOperator{ .eq, .neq, .lt, .lte, .gt, .gte };
    for (ops, 0..) |op, i| buf[i] = if (math.compare(a, op, b)) '1' else '0';
    return buf;
}

fn emitCompare(o: *Out, comptime T: type, ab: Bits(T), bb: Bits(T)) void {
    var buf: [6]u8 = undefined;
    var buf2: [6]u8 = undefined;
    // Value.compare converts both sides to f128 first.
    const a128: f128 = @floatCast(fromBits(T, ab));
    const b128: f128 = @floatCast(fromBits(T, bb));
    const got = cmpWord(&buf, f128, a128, b128);
    const at_width = cmpWord(&buf2, T, fromBits(T, ab), fromBits(T, bb));
    if (!std.mem.eql(u8, got, at_width)) mismatch("compare {s} {x} {x}: f128 {s} width {s}", .{ @typeName(T), ab, bb, got, at_width });
    var prov: []const u8 = PROV_RUN;
    if (refOrder(T, ab, bb)) |ord| {
        var want: [6]u8 = undefined;
        const ops = [_]math.CompareOperator{ .eq, .neq, .lt, .lte, .gt, .gte };
        for (ops, 0..) |op, i| want[i] = if (ord.compare(op)) '1' else '0';
        if (!std.mem.eql(u8, &want, got)) mismatch("compare {s} {x} {x}: zig {s} model {s}", .{ @typeName(T), ab, bb, got, &want });
        prov = PROV_EXACT;
    } else if (decompose(T, ab).kind != .noncanon and decompose(T, bb).kind != .noncanon) {
        // unordered: only != holds
        if (!std.mem.eql(u8, got, "010000")) mismatch("compare NaN {s}: {s}", .{ @typeName(T), got });
        prov = PROV_EXACT;
    }
    o.word("compare");
    o.ty(T);
    o.f(T, ab);
    o.f(T, bb);
    o.eq();
    o.word(got);
    o.end(prov);
}

fn genCompare(o: *Out) void {
    header(o, "std.math.compare after toFloat(f128) (Value.compare float branch), complex !=, classification", "compare compare_complex classify");
    inline for (Widths) |T| {
        o.comment("--- compare {s}", .{@typeName(T)});
        const set = arithSet(T);
        for (set) |a| for (set) |b| emitCompare(o, T, a, b);
        emitCompare(o, T, Std.qnan(T, true, 1), Std.qnan(T, true, 1));
        for (0..20) |_| {
            const a = rndNormal(T, 3);
            emitCompare(o, T, a, a + 1);
            emitCompare(o, T, a, rndNormal(T, 3));
        }
        o.comment("--- compare_complex {s} (Value.compare complex branch, op must be neq)", .{@typeName(T)});
        const cv = [_]Bits(T){ 0, signMask(T), Std.one(T), Std.qnan(T, false, 0), infBits(T, false) };
        for (cv) |ar| for (cv) |ai| for ([_]Bits(T){ 0, Std.one(T), Std.qnan(T, false, 0) }) |br| for ([_]Bits(T){ signMask(T), Std.one(T) }) |bi| {
            const re_eq = math.compare(@as(f128, @floatCast(fromBits(T, ar))), .eq, @as(f128, @floatCast(fromBits(T, br))));
            const im_eq = math.compare(@as(f128, @floatCast(fromBits(T, ai))), .eq, @as(f128, @floatCast(fromBits(T, bi))));
            const neq = !re_eq or !im_eq;
            const model_neq = refOrder(T, ar, br) != .eq or refOrder(T, ai, bi) != .eq;
            if (neq != model_neq) mismatch("compare_complex {s}", .{@typeName(T)});
            o.word("compare_complex");
            o.ty(T);
            o.f(T, ar);
            o.f(T, ai);
            o.f(T, br);
            o.f(T, bi);
            o.eq();
            o.word(if (neq) "1" else "0");
            o.end(PROV_EXACT);
        };
        o.comment("--- classify {s}: std.math predicates (isNan, isInf, x == 0, isNormal) and signbit", .{@typeName(T)});
        var cls: std.ArrayList(Bits(T)) = .empty;
        for (arithSet(T)) |b| cls.append(gpa, b) catch oom();
        for ([_]Bits(T){ signMask(T), Std.maxSub(T), Std.neg(T, Std.minNorm(T)), Std.snan(T, true, 1), Std.qnan(T, true, 0) }) |b| cls.append(gpa, b) catch oom();
        if (T == f80) for ([_]u80{ 0x7fff_0000000000000001, 0x7fff_4000000000000000, 0x7fff_0000000000000000, 0xffff_0000000000000000, 0x3fff_4000000000000000, 0x0000_8000000000000000, 0x8000_c000000000000000 }) |b| cls.append(gpa, b) catch oom();
        for (cls.items) |b| {
            const x = fromBits(T, b);
            const class: []const u8 = if (math.isNan(x)) "nan" else if (math.isInf(x)) "inf" else if (x == 0) "zero" else if (math.isNormal(x)) "normal" else "subnormal";
            const d = decompose(T, b);
            var prov: []const u8 = PROV_EXACT;
            const want: []const u8 = switch (d.kind) {
                .zero => "zero",
                .inf => "inf",
                .nan => "nan",
                .noncanon => "",
                .finite => blk: {
                    const wide: u128 = b;
                    const e = if (comptime fmtOf(T).explicit) (wide >> 64) & 0x7fff else (wide >> ((comptime fmtOf(T)).p - 1)) & emaxField(T);
                    break :blk if (e == 0) "subnormal" else "normal";
                },
            };
            if (d.kind == .noncanon) prov = PROV_RUN else if (!std.mem.eql(u8, want, class)) mismatch("classify {s} {x}: {s} vs {s}", .{ @typeName(T), b, class, want });
            o.word("classify");
            o.ty(T);
            o.f(T, b);
            o.eq();
            o.word(class);
            o.word(if (math.signbit(x)) "neg" else "pos");
            o.end(prov);
        }
    }
}

fn genPrint(o: *Out) void {
    header(o, "Value.print float and complex arms; Zig `{d}` of an f64", "format_f64 print print_complex");
    var buf: [2048]u8 = undefined;
    o.comment("--- format_f64: w.print(\"{{d}}\", .{{x}}) for an f64", .{});
    const lits = [_][]const u8{ "0", "1", "0.1", "0.5", "1.5", "2.5", "-2.5", "100", "123456789", "1e15", "1e16", "1e21", "1e22", "1.5e300", "1e-5", "1e-7", "1.234e-7", "123.456", "0.3", "1e100", "3.141592653589793", "2.718281828459045", "9007199254740993", "4.9e-324", "2.2250738585072014e-308", "1.7976931348623157e308", "5e-324", "0.000001", "1234567.0001" };
    var f64s: std.ArrayList(u64) = .empty;
    for (lits) |s| {
        const v = std.fmt.parseFloat(f64, s) catch unreachable;
        f64s.append(gpa, toBits(f64, v)) catch oom();
        f64s.append(gpa, toBits(f64, -v)) catch oom();
    }
    for ([_]u64{ toBits(f64, math.inf(f64)), toBits(f64, -math.inf(f64)), 0x7ff8_0000_0000_0000, 0xfff8_0000_0000_0001, 0x7ff0_0000_0000_0001 }) |b| f64s.append(gpa, b) catch oom();
    for (0..30) |_| f64s.append(gpa, rndBits(f64)) catch oom();
    for (f64s.items) |b| {
        const x = fromBits(f64, b);
        const s = std.fmt.bufPrint(&buf, "{d}", .{x}) catch unreachable;
        checkRoundTrip(s, x);
        o.word("format_f64");
        o.f(f64, b);
        o.eq();
        o.str(s);
        o.end(PROV_RUN);
    }
    inline for (Widths) |T| {
        o.comment("--- print {s}", .{@typeName(T)});
        var vals: std.ArrayList(Bits(T)) = .empty;
        const plits = [_][]const u8{ "0", "1", "0.1", "0.5", "1.5", "0.0005", "0.0015", "0.0025", "0.00049", "1234.5678", "65504", "1e-5", "1e-7", "3.14159265358979", "100.125", "2.5e-6", "4.5e-7", "1e30", "1e300", "1e400", "1e-310", "-0.0", "-1.75", "-0.0004", "-0.00000004", "0.0000005" };
        for (plits) |s| {
            const v128 = std.fmt.parseFloat(f128, s) catch unreachable;
            vals.append(gpa, toBits(T, @floatCast(launder(f128, v128)))) catch oom();
        }
        for ([_]Bits(T){ Std.max(T), Std.minSub(T), Std.minNorm(T), infBits(T, false), infBits(T, true), Std.qnan(T, false, 0), Std.qnan(T, true, 0) }) |b| vals.append(gpa, b) catch oom();
        for (0..10) |_| vals.append(gpa, rndBits(T)) catch oom();
        for (0..6) |_| vals.append(gpa, rndNormal(T, 10)) catch oom();
        for (vals.items) |b| {
            const x = fromBits(T, b);
            const s = printFloat(T, x, &buf);
            checkRoundTrip(s, printedValue(T, x));
            o.word("print");
            o.ty(T);
            o.f(T, b);
            o.eq();
            o.str(s);
            o.end(PROV_RUN);
        }
        o.comment("--- print_complex {s}", .{@typeName(T)});
        for (0..12) |i| {
            const re = vals.items[(i * 7) % vals.items.len];
            const im = vals.items[(i * 5 + 3) % vals.items.len];
            const s = printComplex(T, fromBits(T, re), fromBits(T, im), &buf);
            o.word("print_complex");
            o.ty(T);
            o.f(T, re);
            o.f(T, im);
            o.eq();
            o.str(s);
            o.end(PROV_RUN);
        }
    }
}

fn checkRoundTrip(s: []const u8, x: f64) void {
    if (math.isNan(x)) {
        if (!std.mem.eql(u8, s, if (math.signbit(x)) "-nan" else "nan")) mismatch("print nan: {s}", .{s});
        return;
    }
    if (math.isInf(x)) {
        if (!std.mem.eql(u8, s, if (x < 0) "-inf" else "inf")) mismatch("print inf: {s}", .{s});
        return;
    }
    if (std.mem.indexOfAny(u8, s, "eE") != null) mismatch("print uses exponent: {s}", .{s});
    const back = std.fmt.parseFloat(f64, s) catch {
        mismatch("print unparsable: {s}", .{s});
        return;
    };
    if (toBits(f64, back) != toBits(f64, x)) mismatch("print round trip: {s} -> {x} want {x}", .{ s, toBits(f64, back), toBits(f64, x) });
}

fn emitParse(o: *Out, comptime T: type, s: []const u8) void {
    const v128 = std.fmt.parseFloat(f128, s) catch unreachable;
    const got = toBits(T, @floatCast(launder(f128, v128)));
    const direct = toBits(T, std.fmt.parseFloat(T, s) catch unreachable);
    const model: Bits(T) = switch (refCast(f128, T, toBits(f128, v128))) {
        .bits => |b| @intCast(b),
        else => got,
    };
    if (model != got) mismatch("parse {s} {s}: cast {x} model {x}", .{ @typeName(T), s, got, model });
    o.word("parse");
    o.ty(T);
    o.word(s);
    o.eq();
    o.f(T, got);
    o.end(if (got == direct) PROV_RUN else PROV_DBL);
}

/// Exact decimal expansion of m * 2^e (e < 0) followed by `tail` digits.
fn decimalOf(m: u128, e: i64, tail: []const u8) []const u8 {
    // m * 2^e = m * 5^-e / 10^-e
    const k: usize = @intCast(-e);
    var five = big(1);
    for (0..k) |_| five = bigMul(five, big(5));
    const num = bigMul(big(m), five);
    const digits = num.toString(gpa, 10, .lower) catch oom();
    var out: std.ArrayList(u8) = .empty;
    if (digits.len <= k) {
        out.appendSlice(gpa, "0.") catch oom();
        for (0..k - digits.len) |_| out.append(gpa, '0') catch oom();
        out.appendSlice(gpa, digits) catch oom();
    } else {
        out.appendSlice(gpa, digits[0 .. digits.len - k]) catch oom();
        out.append(gpa, '.') catch oom();
        out.appendSlice(gpa, digits[digits.len - k ..]) catch oom();
    }
    out.appendSlice(gpa, tail) catch oom();
    return out.items;
}

fn genParse(o: *Out) void {
    header(o, "Parser.parseFloat: std.fmt.parseFloat(f128, s) then @floatCast to the literal's width", "parse");
    const lits = [_][]const u8{
        "0",                                               "0.0",                                  "1",                                                    "1.",
        ".5",                                              "0.1",                                  "0.2",                                                  "0.3",
        "1.5",                                             "2.5",                                  "3.14159265358979323846264338327950288419716939937510", "1e10",
        "1E10",                                            "1e+5",                                 "1e-10",                                                "123456789012345678901234567890",
        "0.000000000000000000000000000000000000000000001", "65504",                                "65519.99",                                             "65520",
        "6.103515625e-05",                                 "5.9604644775390625e-08",               "2.98e-8",                                              "3.4028234663852886e38",
        "3.4028235e38",                                    "3.4028236e38",                         "1.17549435e-38",                                       "1.4e-45",
        "7e-46",                                           "1.7976931348623157e308",               "1.7976931348623158e308",                               "1.8e308",
        "2.2250738585072014e-308",                         "4.9e-324",                             "2.4703282292062328e-324",                              "2.4703282292062327e-324",
        "1e-400",                                          "1.18973149535723176502e4932",          "1.2e4932",                                             "3.6e-4951",
        "6.5e-4966",                                       "1e5000",                               "1e-5000",                                              "0x1p0",
        "0x1.8p1",                                         "0X1P+0",                               "0x.8p1",                                               "0x1p-1074",
        "0x1.fffffffffffffp1023",                          "0x1.fffffffffffff8p1023",              "0x1.000001p0",                                         "0x1.0000018p0",
        "0x1.00000000000008p0",                            "0x1.000000000000080000000000000001p0", "0xffp-4",                                              "0x1p-16494",
        "0x1p-16495",                                      "0x1p16384",                            "0x1.ffffffffffffffffffffffffffffp16383",
    };
    inline for (Widths) |T| {
        o.comment("--- parse {s}", .{@typeName(T)});
        for (lits) |s| emitParse(o, T, s);
    }
    o.comment("--- double rounding: decimal just above a midpoint of the narrow width,", .{});
    o.comment("--- below f128 precision, so f128 lands on the midpoint and ties to even", .{});
    inline for ([_]type{ f16, f32, f64, f80 }) |T| {
        const f = comptime fmtOf(T);
        const tail = "00000000000000000000000000000000000000000000000001";
        for ([_]u128{ 0, 2, 4, 0x1234 & ((@as(u128, 1) << (f.p - 1)) - 1) & ~@as(u128, 1) }) |m_low| {
            // value = (2^(p-1) + m_low + 1/2) * 2^-(p-1) in [1,2): midpoint between two even/odd neighbours
            const mid_m = ((@as(u128, 1) << (f.p - 1)) + m_low) * 2 + 1;
            const s = decimalOf(mid_m, -@as(i64, f.p), tail);
            emitParse(o, T, s);
            emitParse(o, T, decimalOf(mid_m, -@as(i64, f.p), "")); // exact midpoint
        }
    }
}

/// Model scalbn: exact x * 2^n rounded once; zero, inf and NaN unchanged.
fn modelScalbn(comptime T: type, x: Bits(T), n: i64) Bits(T) {
    const d = decompose(T, x);
    if (d.kind != .finite) return x;
    return roundTo(T, d.neg, big(d.sig), @as(i64, d.exp) + n, false);
}

/// annex_g.zig re-expressed over bit patterns with the exact model operations
/// (line for line the same control flow as the verbatim copy at the top).
/// With `zig_scalbn`, scalbn calls Zig's std.math.scalbn instead of the model,
/// which isolates disagreements caused by std.math.ldexp.
fn ModelAnnex(comptime T: type, comptime zig_scalbn: bool) type {
    return struct {
        const B = Bits(T);
        fn mul(x: B, y: B) B {
            // (non-canonical f80 input can only come from Zig's scalbn in the
            // diagnostic zig_scalbn model; fall back to the run there)
            return modelArith(T, .mul, x, y) orelse zigArith(T, .mul, x, y);
        }
        fn add(x: B, y: B) B {
            // (non-canonical f80 input can only come from Zig's scalbn in the
            // diagnostic zig_scalbn model; fall back to the run there)
            return modelArith(T, .add, x, y) orelse zigArith(T, .add, x, y);
        }
        fn sub(x: B, y: B) B {
            // (non-canonical f80 input can only come from Zig's scalbn in the
            // diagnostic zig_scalbn model; fall back to the run there)
            return modelArith(T, .sub, x, y) orelse zigArith(T, .sub, x, y);
        }
        fn div(x: B, y: B) B {
            // (non-canonical f80 input can only come from Zig's scalbn in the
            // diagnostic zig_scalbn model; fall back to the run there)
            return modelArith(T, .div, x, y) orelse zigArith(T, .div, x, y);
        }
        fn isNan(x: B) bool {
            return isNanBits(T, x);
        }
        fn isInf(x: B) bool {
            return decompose(T, x).kind == .inf;
        }
        fn isFinite(x: B) bool {
            const k = decompose(T, x).kind;
            return k == .zero or k == .finite;
        }
        fn copysign(mag: B, sgn: B) B {
            return (mag & ~signMask(T)) | (sgn & signMask(T));
        }
        fn one() B {
            return Std.one(T);
        }
        fn inf() B {
            return infBits(T, false);
        }
        fn ilogb(x: B) i32 {
            const d = decompose(T, x);
            return switch (d.kind) {
                .zero, .nan, .noncanon => std.math.minInt(i32),
                .inf => std.math.maxInt(i32),
                .finite => @as(i32, @intCast(128 - @clz(d.sig))) - 1 + d.exp,
            };
        }
        fn scalbn(x: B, n: i32) B {
            if (zig_scalbn) return toBits(T, math.scalbn(fromBits(T, x), n));
            return modelScalbn(T, x, n);
        }
        /// @max of two non-negative values (LLVM maxnum: a NaN operand loses).
        fn max(x: B, y: B) B {
            if (isNan(x)) return y;
            if (isNan(y)) return x;
            return if (refOrder(T, x, y) == .lt) y else x;
        }

        fn complexMul(a_param: B, b_param: B, c_param: B, d_param: B) [2]B {
            var a = a_param;
            var b = b_param;
            var c = c_param;
            var d = d_param;
            const ac = mul(a, c);
            const bd = mul(b, d);
            const ad = mul(a, d);
            const bc = mul(b, c);
            var x = sub(ac, bd);
            var y = add(ad, bc);
            if (isNan(x) and isNan(y)) {
                var recalc = false;
                if (isInf(a) or isInf(b)) {
                    a = copysign(if (isInf(a)) one() else 0, a);
                    b = copysign(if (isInf(b)) one() else 0, b);
                    if (isNan(c)) c = copysign(0, c);
                    if (isNan(d)) d = copysign(0, d);
                    recalc = true;
                }
                if (isInf(c) or isInf(d)) {
                    c = copysign(if (isInf(c)) one() else 0, c);
                    d = copysign(if (isInf(d)) one() else 0, d);
                    if (isNan(a)) a = copysign(0, a);
                    if (isNan(b)) b = copysign(0, b);
                    recalc = true;
                }
                if (!recalc and (isInf(ac) or isInf(bd) or isInf(ad) or isInf(bc))) {
                    if (isNan(a)) a = copysign(0, a);
                    if (isNan(b)) b = copysign(0, b);
                    if (isNan(c)) c = copysign(0, c);
                    if (isNan(d)) d = copysign(0, d);
                }
                if (recalc) {
                    x = mul(inf(), sub(mul(a, c), mul(b, d)));
                    y = mul(inf(), add(mul(a, d), mul(b, c)));
                }
            }
            return .{ x, y };
        }

        fn complexDiv(a_param: B, b_param: B, c_param: B, d_param: B) [2]B {
            var a = a_param;
            var b = b_param;
            var c = c_param;
            var d = d_param;
            var denom_logb: i32 = 0;
            const max_cd = max(c & ~signMask(T), d & ~signMask(T));
            if (isFinite(max_cd)) {
                if (decompose(T, max_cd).kind == .zero) {
                    denom_logb = std.math.minInt(i32) + 1;
                    c = 0;
                    d = 0;
                } else {
                    denom_logb = ilogb(max_cd);
                    c = scalbn(c, -denom_logb);
                    d = scalbn(d, -denom_logb);
                }
            }
            const denom = add(mul(c, c), mul(d, d));
            var x = scalbn(div(add(mul(a, c), mul(b, d)), denom), -denom_logb);
            var y = scalbn(div(sub(mul(b, c), mul(a, d)), denom), -denom_logb);
            if (isNan(x) and isNan(y)) {
                if (denom == 0 and (!isNan(a) or !isNan(b))) {
                    x = mul(copysign(inf(), c), a);
                    y = mul(copysign(inf(), c), b);
                } else if ((isInf(a) or isInf(b)) and isFinite(c) and isFinite(d)) {
                    a = copysign(if (isInf(a)) one() else 0, a);
                    b = copysign(if (isInf(b)) one() else 0, b);
                    x = mul(inf(), add(mul(a, c), mul(b, d)));
                    y = mul(inf(), sub(mul(b, c), mul(a, d)));
                } else if (isInf(max_cd) and isFinite(a) and isFinite(b)) {
                    c = copysign(if (isInf(c)) one() else 0, c);
                    d = copysign(if (isInf(d)) one() else 0, d);
                    x = mul(0, add(mul(a, c), mul(b, d)));
                    y = mul(0, sub(mul(b, c), mul(a, d)));
                }
            }
            return .{ x, y };
        }
    };
}

fn emitComplex(o: *Out, comptime T: type, name: []const u8, a: Bits(T), b: Bits(T), c: Bits(T), d: Bits(T), prov_in: []const u8) [2]Bits(T) {
    const A = fromBits(T, a);
    const B = fromBits(T, b);
    const C = fromBits(T, c);
    const D = fromBits(T, d);
    const MA = ModelAnnex(T, false);
    const MZ = ModelAnnex(T, true);
    var model: [2]Bits(T) = undefined;
    var model_zs: [2]Bits(T) = undefined;
    const r: [2]T = if (std.mem.eql(u8, name, "cmul")) blk: {
        model = MA.complexMul(a, b, c, d);
        model_zs = MZ.complexMul(a, b, c, d);
        break :blk annex_g.complexFloatMul(T, A, B, C, D);
    } else if (std.mem.eql(u8, name, "cdiv")) blk: {
        model = MA.complexDiv(a, b, c, d);
        model_zs = MZ.complexDiv(a, b, c, d);
        break :blk annex_g.complexFloatDiv(T, A, B, C, D);
    } else if (std.mem.eql(u8, name, "cadd")) blk: {
        // Value.complexAddSub(.add)
        model = .{ modelArith(T, .add, a, c).?, modelArith(T, .add, b, d).? };
        model_zs = model;
        break :blk .{ A + C, B + D };
    } else blk: {
        model = .{ modelArith(T, .sub, a, c).?, modelArith(T, .sub, b, d).? };
        model_zs = model;
        break :blk .{ A - C, B - D };
    };
    const got = [2]Bits(T){ toBits(T, r[0]), toBits(T, r[1]) };
    var out = got;
    var prov: []const u8 = PROV_EXACT;
    if (got[0] != model[0] or got[1] != model[1]) {
        // Allowed only when explained by std.math.ldexp (the zig-scalbn model
        // reproduces the run) or by a compiler_rt width.
        if ((got[0] == model_zs[0] and got[1] == model_zs[1]) or crtArith(T)) {
            const digits = comptime std.fmt.comptimePrint("{d}", .{(@bitSizeOf(T) + 3) / 4});
            o.comment("lib-bug: zig-0.17.0 gave 0x{x:0>" ++ digits ++ "} 0x{x:0>" ++ digits ++ "}; the vector holds the model value", .{ got[0], got[1] });
            lib_bugs += 1;
            out = model;
            prov = PROV_LIB;
        } else mismatch("{s} {s} {x} {x} {x} {x}: zig {x} {x}, model {x} {x}", .{ name, @typeName(T), a, b, c, d, got[0], got[1], model[0], model[1] });
    }
    if (std.mem.eql(u8, prov_in, PROV_ARO) and std.mem.eql(u8, prov, PROV_EXACT)) prov = PROV_ARO;
    o.word(name);
    o.ty(T);
    o.f(T, a);
    o.f(T, b);
    o.f(T, c);
    o.f(T, d);
    o.eq();
    o.f(T, out[0]);
    o.f(T, out[1]);
    o.end(prov);
    return out;
}

fn genComplex(o: *Out) void {
    header(o, "Complex: Value.complexAddSub, annex_g.complexFloatMul/Div, Value.complexConj", "cadd csub cmul cdiv conj");
    inline for (Widths) |T| {
        const f = comptime fmtOf(T);
        const one = Std.one(T);
        const two = Std.pow2(T, 1);
        const inf_ = infBits(T, false);
        const ninf = infBits(T, true);
        const nan = Std.qnan(T, false, 0);
        const max = Std.max(T);
        o.comment("--- {s}: embedded test blocks of src/aro/annex_g.zig", .{@typeName(T)});
        {
            const r1 = emitComplex(o, T, "cmul", inf_, toBits(T, math.nan(T)), two, 0, PROV_ARO);
            if (!(decompose(T, r1[0]).kind == .inf and isNanBits(T, r1[1]))) mismatch("annex_g test cmul {s}", .{@typeName(T)});
            const r2 = emitComplex(o, T, "cdiv", inf_, toBits(T, math.nan(T)), two, 0, PROV_ARO);
            if (!(decompose(T, r2[0]).kind == .inf and isNanBits(T, r2[1]))) mismatch("annex_g test cdiv {s}", .{@typeName(T)});
            const r3 = emitComplex(o, T, "cdiv", two, two, 0, 0, PROV_ARO);
            if (!(decompose(T, r3[0]).kind == .inf and decompose(T, r3[1]).kind == .inf)) mismatch("annex_g test cdiv0 {s}", .{@typeName(T)});
        }
        o.comment("--- {s}: special operand cross product (a + bi) op (c + di)", .{@typeName(T)});
        const set4 = [_]Bits(T){ 0, one, inf_, nan };
        const set5 = [_]Bits(T){ 0, one, inf_, ninf, nan };
        const set6 = [_]Bits(T){ 0, signMask(T), one, inf_, ninf, nan };
        const set: []const Bits(T) = switch (T) {
            f64 => &set6,
            f80, f128 => &set4,
            else => &set5,
        };
        for ([_][]const u8{ "cmul", "cdiv" }) |name| for (set) |a| for (set) |b| for (set) |c| for (set) |d| {
            _ = emitComplex(o, T, name, a, b, c, d, PROV_RUN);
        };
        o.comment("--- {s}: Annex G recovery paths, overflow, logb scaling", .{@typeName(T)});
        const quirk = [_][4]Bits(T){
            .{ max, nan, max, 0 }, // overflow-recovery branch without recalc (Aro keeps NaN)
            .{ max, max, max, Std.neg(T, max) },
            .{ max, max, max, max },
            .{ nan, one, inf_, one },
            .{ one, nan, one, inf_ },
            .{ nan, nan, inf_, 0 },
            .{ inf_, inf_, nan, nan },
            .{ one, one, 0, signMask(T) },
            .{ one, one, signMask(T), 0 },
            .{ nan, one, 0, 0 },
            .{ one, nan, 0, 0 },
            .{ 0, 0, 0, 0 },
            .{ inf_, one, one, one },
            .{ one, one, inf_, nan },
            .{ one, one, nan, ninf },
            .{ one, one, max, max },
            .{ max, max, one, one },
            .{ max, max, Std.minSub(T), Std.minSub(T) },
            .{ Std.minSub(T), Std.minSub(T), max, max },
            .{ one, one, Std.minSub(T), Std.minNorm(T) },
            .{ 0, 0, Std.minSub(T), Std.minSub(T) }, // 0 quotient scaled by a large 2^-logb
            .{ 0, signMask(T), Std.minNorm(T), 0 },
            .{ one, 0, Std.minNorm(T), Std.minNorm(T) },
            .{ Std.minNorm(T), max, Std.minNorm(T), max },
            .{ Std.exact(T, false, 3, 0), Std.exact(T, true, 1, 2), Std.exact(T, false, 1, -3), Std.exact(T, false, 5, f.bias - 4) },
        };
        for (quirk) |q| {
            _ = emitComplex(o, T, "cmul", q[0], q[1], q[2], q[3], PROV_RUN);
            _ = emitComplex(o, T, "cdiv", q[0], q[1], q[2], q[3], PROV_RUN);
        }
        o.comment("--- {s}: pseudo-random finite operands", .{@typeName(T)});
        for (0..24) |_| {
            const spread: u32 = if (T == f16) 5 else 40;
            const a = rndNormal(T, spread);
            const b = rndNormal(T, spread);
            const c = rndNormal(T, spread);
            const d = rndNormal(T, spread);
            _ = emitComplex(o, T, "cmul", a, b, c, d, PROV_RUN);
            _ = emitComplex(o, T, "cdiv", a, b, c, d, PROV_RUN);
            _ = emitComplex(o, T, "cadd", a, b, c, d, PROV_RUN);
            _ = emitComplex(o, T, "csub", a, b, c, d, PROV_RUN);
        }
        for (set5) |a| for (set5) |c| {
            _ = emitComplex(o, T, "cadd", a, signMask(T), c, 0, PROV_RUN);
            _ = emitComplex(o, T, "csub", a, 0, c, 0, PROV_RUN);
        };
        o.comment("--- {s}: conj (re, -im): sign flip only, also for +0 and NaN", .{@typeName(T)});
        for ([_]Bits(T){ 0, signMask(T), one, ninf, nan, Std.snan(T, true, 1) }) |im| {
            const r = -fromBits(T, im);
            o.word("conj");
            o.ty(T);
            o.f(T, one);
            o.f(T, im);
            o.eq();
            o.f(T, one);
            o.f(T, toBits(T, r));
            o.end(PROV_RUN);
        }
    }
}

fn genAnnexHelpers(o: *Out) void {
    header(o, "std.math helpers Annex G uses: ilogb, scalbn (ldexp), @max; and @mulAdd(f128)", "ilogb scalbn fmax mul_add");
    inline for (Widths) |T| {
        const f = comptime fmtOf(T);
        var vals: std.ArrayList(Bits(T)) = .empty;
        for (arithSet(T)) |b| vals.append(gpa, b) catch oom();
        for ([_]Bits(T){ Std.maxSub(T), Std.minSub(T) * 6, Std.qnan(T, true, 0), Std.snan(T, false, 1) }) |b| vals.append(gpa, b) catch oom();
        for (0..6) |_| vals.append(gpa, rndBits(T)) catch oom();
        o.comment("--- ilogb {s}", .{@typeName(T)});
        for (vals.items) |b| {
            const got = math.ilogb(fromBits(T, b));
            var prov: []const u8 = PROV_RUN;
            if (decompose(T, b).kind != .noncanon) {
                const want = ModelAnnex(T, false).ilogb(b);
                if (want != got) mismatch("ilogb {s} {x}: zig {d} model {d}", .{ @typeName(T), b, got, want });
                prov = PROV_EXACT;
            }
            o.word("ilogb");
            o.ty(T);
            o.f(T, b);
            o.eq();
            o.dec(got);
            o.end(prov);
        }
        o.comment("--- scalbn {s}", .{@typeName(T)});
        const ns = [_]i32{ 0, 1, -1, 10, -10, f.bias, -f.bias, 2 * f.bias + @as(i32, @intCast(f.p)), -(2 * f.bias + @as(i32, @intCast(f.p))), -(f.bias + @as(i32, @intCast(f.p)) - 2), std.math.maxInt(i32), std.math.minInt(i32) + 1, -std.math.maxInt(i32) };
        for (vals.items) |b| for (ns) |n| {
            const got = toBits(T, math.scalbn(fromBits(T, b), launder(i32, n)));
            const model: ?Bits(T) = if (decompose(T, b).kind == .noncanon) null else modelScalbn(T, b, n);
            const r, const prov = settle(o, T, got, model, true, "scalbn {s} {x} {d}", .{ @typeName(T), b, n });
            o.word("scalbn");
            o.ty(T);
            o.f(T, b);
            o.dec(n);
            o.eq();
            o.f(T, r);
            o.end(prov);
        };
        // scalbn ties when the result is subnormal
        for ([_]u128{ 1, 3, 5, 7, (@as(u128, 1) << (f.p - 1)) + 1, (@as(u128, 1) << (f.p - 1)) + 3 }) |m| {
            const b = Std.exact(T, false, m, 0);
            const n: i32 = 1 - f.bias - @as(i32, @intCast(f.p - 1)) - 1 - (if (m > 8) @as(i32, @intCast(f.p - 1)) else 0);
            const r = toBits(T, math.scalbn(fromBits(T, b), launder(i32, n)));
            const want = roundTo(T, false, big(m), n, false);
            if (want != r) mismatch("scalbn tie {s} {d} {d}: zig {x} model {x}", .{ @typeName(T), m, n, r, want });
            o.word("scalbn");
            o.ty(T);
            o.f(T, b);
            o.dec(n);
            o.eq();
            o.f(T, r);
            o.end(PROV_EXACT);
        }
        o.comment("--- fmax {s}: @max (used on @abs values)", .{@typeName(T)});
        const ms = [_]Bits(T){ 0, signMask(T), Std.one(T), infBits(T, false), Std.qnan(T, false, 1), Std.qnan(T, true, 2) };
        for (ms) |a| for (ms) |b| {
            const r = toBits(T, @max(fromBits(T, a), fromBits(T, b)));
            o.word("fmax");
            o.ty(T);
            o.f(T, a);
            o.f(T, b);
            o.eq();
            o.f(T, r);
            o.end(PROV_RUN);
        };
    }
    o.comment("--- mul_add f128: @mulAdd(f128, a, b, c), one rounding", .{});
    const two64: u128 = toBits(f128, 18446744073709551616.0);
    var cases: std.ArrayList([3]u128) = .empty;
    for (0..20) |_| cases.append(gpa, .{ two64, rndNormal(f128, 120), toBits(f128, @as(f128, @floatFromInt(launder(u64, nextU64())))) }) catch oom();
    for (0..20) |_| cases.append(gpa, .{ rndNormal(f128, 50), rndNormal(f128, 50), rndNormal(f128, 100) }) catch oom();
    cases.append(gpa, .{ toBits(f128, 1.0), toBits(f128, 1.0), Std.neg(f128, toBits(f128, 1.0)) }) catch oom();
    cases.append(gpa, .{ Std.max(f128), toBits(f128, 2.0), Std.neg(f128, Std.max(f128)) }) catch oom();
    cases.append(gpa, .{ Std.minNorm(f128), Std.pow2(f128, -60), Std.minSub(f128) }) catch oom();
    cases.append(gpa, .{ signMask(f128), toBits(f128, 1.0), signMask(f128) }) catch oom();
    cases.append(gpa, .{ infBits(f128, false), 0, toBits(f128, 1.0) }) catch oom();
    cases.append(gpa, .{ two64, infBits(f128, false), toBits(f128, 1.0) }) catch oom();
    for (cases.items) |cs| {
        const r = toBits(f128, @mulAdd(f128, fromBits(f128, cs[0]), fromBits(f128, cs[1]), fromBits(f128, cs[2])));
        var prov: []const u8 = PROV_RUN;
        switch (refFma(cs[0], cs[1], cs[2])) {
            .bits => |w| {
                if (w != r) mismatch("mul_add {x} {x} {x}: zig {x} model {x}", .{ cs[0], cs[1], cs[2], r, w });
                prov = PROV_EXACT;
            },
            else => {},
        }
        o.word("mul_add");
        o.ty(f128);
        o.f(f128, cs[0]);
        o.f(f128, cs[1]);
        o.f(f128, cs[2]);
        o.eq();
        o.f(f128, r);
        o.end(prov);
    }
}

const Gen = struct { file: []const u8, f: *const fn (*Out) void };

pub fn main(init: std.process.Init) !void {
    arena_state = .init(std.heap.page_allocator);
    gpa = arena_state.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(gpa);
    if (args.len != 2) {
        std.debug.print("usage: float_probe <out-dir>\n", .{});
        return error.Usage;
    }
    var dir = try std.Io.Dir.cwd().openDir(io, args[1], .{});
    defer dir.close(io);

    const gens = [_]Gen{
        .{ .file = "arith.txt", .f = genArith },
        .{ .file = "nan.txt", .f = genNan },
        .{ .file = "cast.txt", .f = genCast },
        .{ .file = "int_float.txt", .f = genIntFloat },
        .{ .file = "float_to_int.txt", .f = genFloatToInt },
        .{ .file = "compare.txt", .f = genCompare },
        .{ .file = "print.txt", .f = genPrint },
        .{ .file = "parse.txt", .f = genParse },
        .{ .file = "complex.txt", .f = genComplex },
        .{ .file = "annex_helpers.txt", .f = genAnnexHelpers },
    };
    for (gens) |g| {
        var aw: std.Io.Writer.Allocating = .init(gpa);
        var o: Out = .{ .w = &aw.writer };
        g.f(&o);
        try aw.writer.print("# end: {d} vectors\n", .{o.count});
        try dir.writeFile(io, .{ .sub_path = g.file, .data = aw.written() });
        std.debug.print("{s}: {d} vectors\n", .{ g.file, o.count });
    }

    std.debug.print("NaN rule tallies vs the stage-0 contract (agree/disagree):\n", .{});
    inline for (Widths, 0..) |T, i| {
        std.debug.print("  {s}:", .{@typeName(T)});
        for (nan_tally[i], 0..) |t, j| std.debug.print(" {s} {d}/{d}", .{ @tagName(@as(Op, @fromBackingInt(@intCast(j)))), t.agree, t.disagree });
        std.debug.print("\n", .{});
    }
    inline for (Widths, 0..) |S, i| inline for (Widths, 0..) |D, j| {
        const t = cast_tally[i][j];
        if (t.agree + t.disagree > 0) std.debug.print("  cast {s}->{s}: {d}/{d}\n", .{ @typeName(S), @typeName(D), t.agree, t.disagree });
    };
    std.debug.print("lib-bug vectors (model value kept): {d}\n", .{lib_bugs});
    if (mismatches != 0) {
        std.debug.print("{d} mismatches against the model\n", .{mismatches});
        if (canonical) return error.Mismatch;
        std.debug.print("(non-canonical configuration: not an error; use the output only for diffing)\n", .{});
    }
}
