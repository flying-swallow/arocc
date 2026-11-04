//! Development-only generator for the literal-decoding vectors in
//! test/c3/data/literals/ (plan 11, agent 11.5). Nothing in a production or
//! Bazel target uses it.
//!
//! Usage (standalone Zig 0.17.0, see test/c3/data/literals/README.md):
//!   zig run test/migration/literal_probe.zig -- test/c3/data/literals
//!
//! The Aro tree needs Zig 0.18-dev and cannot be imported here, so this file
//! carries copies of
//!   - src/aro/Tokenizer/number_literal.zig   (Prefix, Suffix, Parser): verbatim,
//!   - src/aro/Tokenizer/text_literal.zig     (Item, Kind, Ascii, Parser): verbatim,
//!   - src/aro/Parser.zig parseNumberToken / parseInt / fixedSizeInt / bitInt /
//!     parseFloat / getMSVCIntSuffixType / charLiteral / stringLiteral,
//!   - src/aro/Preprocessor/Parser.zig primaryExpr (.pp_num and char literals),
//!   - src/aro/Preprocessor.zig unescapeUcn (the decoding loop),
//!   - the Compilation / LangOpts / Target / TypeStore helpers they call
//!     (wcharMax, float80Type, intLeastN, smallestNBitIntTargetIndependent,
//!     getCharSignedness, allowFixedSizedIntSuffixes, hasChar8_T, intMaxType,
//!     hasInt128, the wchar switch of initNamedTypes, intRank / intRankOrder,
//!     bitSizeof, Value.intCast / maxInt), and Diagnostics.formatArgs.
//! Changes from the originals, all mechanical:
//!   - AST nodes, the interner and the token list are dropped; values are plain
//!     Zig floats / big ints and a QualType is a small struct (QualType below);
//!   - diagnostics are *recorded* (template id, token index, byte offset, text)
//!     instead of reported. A diagnostic is recorded where Zig would call
//!     `effectiveKind`, i.e. before the "off" filter: number_literal `err`,
//!     text_literal `warn` after its `errored` check, Parser/Preprocessor `err`
//!     unconditionally. The `errored` latch of text_literal therefore behaves
//!     exactly as in Zig regardless of which diagnostics are enabled;
//!   - std.Target comes from Zig 0.17.0 (cTypeBitSize, cCharSignedness,
//!     ptrBitWidth); Aro's own Target.zig switches are copied.
//!   - the copied `Diagnostic` constants are all `pub` (so they can be named);
//!   - where the Zig code reaches safety-checked illegal behaviour (parseFloat's
//!     `catch unreachable`, `Ascii.init` / char `@intCast` overflow, bitInt's
//!     width cast) the probe flags it and the vector records `unreachable`.
//! The probe also re-evaluates every vector of fixtures.txt (written by
//! test/migration/literal_fixtures.py) and prints disagreements.

const std = @import("std");
const mem = std.mem;
const assert = std.debug.assert;
const big = std.math.big;
const Signedness = std.builtin.Signedness;

var arena_state: std.heap.ArenaAllocator = undefined;
var gpa: mem.Allocator = undefined;
/// Set when the copied Zig code reaches safety-checked illegal behaviour
/// (a panic in Debug, undefined behaviour in release builds of Aro).
var zig_unreachable: ?[]const u8 = null;

/// Set by parseFloat when parse-to-f128-then-@floatCast differs from one
/// direct rounding (README "Double rounding").
var dbl_round = false;

/// The Compilation of the vector being computed and how many diagnostics it
/// had recorded when Zig would have panicked (later ones are dropped).
var active_comp: ?*Compilation = null;
var unreachable_diags: usize = 0;

fn zigUnreachable(why: []const u8) void {
    if (zig_unreachable == null) {
        zig_unreachable = why;
        unreachable_diags = active_comp.?.diags.items.len;
    }
}

// ===========================================================================
// Mini Compilation
// ===========================================================================

const Standard = enum {
    c89,
    iso9899,
    gnu89,
    c99,
    gnu99,
    c11,
    gnu11,
    c17,
    default,
    gnu17,
    c23,
    gnu23,
    c2y,
    gnu2y,

    pub fn atLeast(self: Standard, other: Standard) bool {
        return @backingInt(self) >= @backingInt(other);
    }
};

const LangOpts = struct {
    const Compiler = enum { clang, gcc, msvc, no };
    emulate: Compiler = .no,
    standard: Standard = .default,
    ms_extensions: bool = false,
    char_signedness_override: ?Signedness = null,
    has_char8_t_override: ?bool = null,
    has_int24: bool = false,

    pub fn hasChar8_T(self: *const LangOpts) bool {
        return self.has_char8_t_override orelse self.standard.atLeast(.c23);
    }

    pub fn allowFixedSizedIntSuffixes(self: *const LangOpts) bool {
        return switch (self.emulate) {
            .msvc => true,
            .clang, .no => self.ms_extensions,
            .gcc => false,
        };
    }
};

const Int = enum {
    char,
    schar,
    uchar,
    short,
    ushort,
    int,
    uint,
    long,
    ulong,
    long_long,
    ulong_long,
    int128,
    uint128,
    int24,
    uint24,

    pub fn bits(int: Int, comp: *const Compilation) u16 {
        return switch (int) {
            .char => comp.target.cTypeBitSize(.char).?,
            .schar => comp.target.cTypeBitSize(.char).?,
            .uchar => comp.target.cTypeBitSize(.char).?,
            .short => comp.target.cTypeBitSize(.short).?,
            .ushort => comp.target.cTypeBitSize(.ushort).?,
            .int => comp.target.cTypeBitSize(.int).?,
            .uint => comp.target.cTypeBitSize(.uint).?,
            .long => comp.target.cTypeBitSize(.long).?,
            .ulong => comp.target.cTypeBitSize(.ulong).?,
            .long_long => comp.target.cTypeBitSize(.longlong).?,
            .ulong_long => comp.target.cTypeBitSize(.ulonglong).?,
            .int128 => 128,
            .uint128 => 128,
            .int24, .uint24 => 24,
        };
    }
};

const Float = enum {
    bf16,
    fp16,
    float16,
    float,
    double,
    long_double,
    float128,
    float32,
    float64,
    float32x,
    float64x,
    float128x,
    dfloat32,
    dfloat64,
    dfloat128,
    dfloat64x,

    pub fn bits(float: Float, comp: *const Compilation) u16 {
        return switch (float) {
            .bf16 => 16,
            .fp16 => 16,
            .float16 => 16,
            .float => comp.target.cTypeBitSize(.float).?,
            .double => comp.target.cTypeBitSize(.double).?,
            .long_double => comp.target.cTypeBitSize(.longdouble).?,
            .float128 => 128,
            .float32 => 32,
            .float64 => 64,
            .float32x => 32 * 2,
            .float64x => 64 * 2,
            .float128x => unreachable, // Not supported
            .dfloat32 => 32,
            .dfloat64 => 64,
            .dfloat128 => 128,
            .dfloat64x => 64 * 2,
        };
    }
};

/// The few QualType shapes literals produce. Decl literals (`.int`,
/// `.ulong_long`, `.double`, ...) keep the copied code verbatim.
const QualType = struct {
    tag: enum { int, float, bit_int, array } = .int,
    t_int: Int = .int,
    t_float: Float = .double,
    bits: u16 = 0,
    sign: Signedness = .signed,
    complex: bool = false,
    /// array element (an int type) and length
    elem: Int = .char,
    len: u64 = 0,

    pub const char: QualType = .{ .t_int = .char };
    pub const schar: QualType = .{ .t_int = .schar };
    pub const uchar: QualType = .{ .t_int = .uchar };
    pub const short: QualType = .{ .t_int = .short };
    pub const ushort: QualType = .{ .t_int = .ushort };
    pub const int: QualType = .{ .t_int = .int };
    pub const uint: QualType = .{ .t_int = .uint };
    pub const long: QualType = .{ .t_int = .long };
    pub const ulong: QualType = .{ .t_int = .ulong };
    pub const long_long: QualType = .{ .t_int = .long_long };
    pub const ulong_long: QualType = .{ .t_int = .ulong_long };
    pub const int128: QualType = .{ .t_int = .int128 };
    pub const uint128: QualType = .{ .t_int = .uint128 };
    pub const int24: QualType = .{ .t_int = .int24 };
    pub const uint24: QualType = .{ .t_int = .uint24 };

    pub const bf16: QualType = .{ .tag = .float, .t_float = .bf16 };
    pub const float16: QualType = .{ .tag = .float, .t_float = .float16 };
    pub const float: QualType = .{ .tag = .float, .t_float = .float };
    pub const double: QualType = .{ .tag = .float, .t_float = .double };
    pub const long_double: QualType = .{ .tag = .float, .t_float = .long_double };
    pub const float128: QualType = .{ .tag = .float, .t_float = .float128 };
    pub const float32: QualType = .{ .tag = .float, .t_float = .float32 };
    pub const float64: QualType = .{ .tag = .float, .t_float = .float64 };
    pub const float32x: QualType = .{ .tag = .float, .t_float = .float32x };
    pub const float64x: QualType = .{ .tag = .float, .t_float = .float64x };
    pub const dfloat32: QualType = .{ .tag = .float, .t_float = .dfloat32 };
    pub const dfloat64: QualType = .{ .tag = .float, .t_float = .dfloat64 };
    pub const dfloat128: QualType = .{ .tag = .float, .t_float = .dfloat128 };
    pub const dfloat64x: QualType = .{ .tag = .float, .t_float = .dfloat64x };

    fn eql(a: QualType, b: QualType) bool {
        if (a.tag != b.tag or a.complex != b.complex) return false;
        return switch (a.tag) {
            .int => a.t_int == b.t_int,
            .float => a.t_float == b.t_float,
            .bit_int => a.bits == b.bits and a.sign == b.sign,
            .array => a.elem == b.elem and a.len == b.len,
        };
    }

    pub fn bitSizeof(qt: QualType, comp: *const Compilation) u64 {
        assert(!qt.complex);
        return switch (qt.tag) {
            .int => qt.t_int.bits(comp),
            .float => qt.t_float.bits(comp),
            .bit_int => qt.bits,
            .array => unreachable,
        };
    }

    pub fn sizeof(qt: QualType, comp: *const Compilation) u64 {
        return (qt.bitSizeof(comp) + 7) / 8;
    }

    pub fn signedness(qt: QualType, comp: *const Compilation) Signedness {
        return switch (qt.tag) {
            .bit_int => qt.sign,
            .int => switch (qt.t_int) {
                .char => comp.getCharSignedness(),
                .schar, .short, .int, .long, .long_long, .int128, .int24 => .signed,
                .uchar, .ushort, .uint, .ulong, .ulong_long, .uint128, .uint24 => .unsigned,
            },
            else => unreachable,
        };
    }

    // TypeStore.QualType.intRank (int and bit_int arms)
    pub fn intRank(qt: QualType, comp: *const Compilation) usize {
        return switch (qt.tag) {
            .bit_int => @as(usize, qt.bits) * 8,
            .int => switch (qt.t_int) {
                .char, .schar, .uchar => 2 + (@as(usize, qt.t_int.bits(comp)) * 8),
                .short, .ushort => 3 + (@as(usize, qt.t_int.bits(comp)) * 8),
                .int, .uint => 4 + (@as(usize, qt.t_int.bits(comp)) * 8),
                .int24, .uint24 => 5 + (@as(usize, qt.t_int.bits(comp)) * 8),
                .long, .ulong => 6 + (@as(usize, qt.t_int.bits(comp)) * 8),
                .long_long, .ulong_long => 7 + (@as(usize, qt.t_int.bits(comp)) * 8),
                .int128, .uint128 => 8 + (@as(usize, qt.t_int.bits(comp)) * 8),
            },
            else => unreachable,
        };
    }

    // TypeStore.QualType.intRankOrder (verbatim)
    pub fn intRankOrder(a: QualType, b: QualType, comp: *const Compilation) std.math.Order {
        const a_unsigned = a.signedness(comp) == .unsigned;
        const b_unsigned = b.signedness(comp) == .unsigned;

        const a_rank = a.intRank(comp);
        const b_rank = b.intRank(comp);
        if (a_unsigned == b_unsigned) {
            return std.math.order(a_rank, b_rank);
        }
        if (a_unsigned) {
            if (a_rank >= b_rank) return .gt;
            return .lt;
        }
        std.debug.assert(b_unsigned);
        if (b_rank >= a_rank) return .lt;
        return .gt;
    }

    pub fn toComplex(qt: QualType, comp: *Compilation) !QualType {
        _ = comp;
        assert(!qt.complex);
        var r = qt;
        r.complex = true;
        return r;
    }

    pub fn format(qt: QualType, w: *std.Io.Writer) !void {
        if (qt.complex) try w.writeAll("complex_");
        switch (qt.tag) {
            .int => try w.writeAll(@tagName(qt.t_int)),
            .float => try w.writeAll(@tagName(qt.t_float)),
            .bit_int => try w.print("bitint_{s}{d}", .{ if (qt.sign == .signed) "s" else "u", qt.bits }),
            .array => try w.print("{s}[{d}]", .{ @tagName(qt.elem), qt.len }),
        }
    }
};

const Diag = struct {
    name: []const u8,
    tok: u32,
    offset: u32,
    text: []const u8,
};

const Compilation = struct {
    target: std.Target,
    langopts: LangOpts,
    type_store: struct {
        wchar: QualType,
        intmax: QualType,
        uint_least16_t: QualType,
        uint_least32_t: QualType,
    } = undefined,
    gpa: mem.Allocator,
    /// recorded diagnostics
    diags: std.ArrayList(Diag) = .empty,
    /// token index recorded with every diagnostic
    cur_tok: u32 = 0,

    pub const CharUnitSize = enum(u32) {
        @"1" = 1,
        @"2" = 2,
        @"4" = 4,

        pub fn Type(comptime self: CharUnitSize) type {
            return switch (self) {
                .@"1" => u8,
                .@"2" => u16,
                .@"4" => u32,
            };
        }
    };

    fn record(comp: *Compilation, name: []const u8, offset: u32, text: []const u8) void {
        comp.diags.append(gpa, .{ .name = name, .tok = comp.cur_tok, .offset = offset, .text = gpa.dupe(u8, text) catch @panic("oom") }) catch @panic("oom");
    }

    // Compilation.float80Type
    pub fn float80Type(comp: *const Compilation) ?QualType {
        return switch (comp.langopts.emulate) {
            .no, .gcc => targetFloat80Type(&comp.target),
            .msvc, .clang => null,
        };
    }

    // Compilation.smallestNBitIntTargetIndependent
    pub fn smallestNBitIntTargetIndependent(comp: *const Compilation, bits: usize, signedness: std.builtin.Signedness) QualType {
        const candidates: [6]QualType = switch (signedness) {
            .signed => .{ .schar, .short, .int, .long, .long_long, .int128 },
            .unsigned => .{ .uchar, .ushort, .uint, .ulong, .ulong_long, .uint128 },
        };
        for (candidates) |qt| {
            if (qt.bitSizeof(comp) >= bits) return qt;
        } else unreachable;
    }

    // Compilation.intLeastN
    pub fn intLeastN(comp: *const Compilation, bits: usize, signedness: std.builtin.Signedness) QualType {
        if (bits <= 24 and bits > Int.int.bits(comp) and comp.langopts.has_int24) {
            return if (signedness == .signed) .int24 else .uint24;
        }
        if (bits == 64 and (comp.target.os.tag.isDarwin() or comp.target.cpu.arch.isWasm())) {
            // WebAssembly and Darwin use `long long` for `int_least64_t` and `int_fast64_t`.
            return if (signedness == .signed) .long_long else .ulong_long;
        }
        if (bits == 16 and comp.target.cpu.arch == .avr) {
            // AVR uses int for int_least16_t and int_fast16_t.
            return if (signedness == .signed) .int else .uint;
        }
        return comp.smallestNBitIntTargetIndependent(bits, signedness);
    }

    // Compilation.wcharMax
    pub fn wcharMax(comp: *const Compilation) u32 {
        const unsigned = comp.type_store.wchar.signedness(comp) == .unsigned;
        return switch (comp.type_store.wchar.bitSizeof(comp)) {
            8 => if (unsigned) std.math.maxInt(u8) else std.math.maxInt(i8),
            16 => if (unsigned) std.math.maxInt(u16) else std.math.maxInt(i16),
            32 => if (unsigned) std.math.maxInt(u32) else std.math.maxInt(i32),
            else => unreachable,
        };
    }

    // Compilation.getCharSignedness
    pub fn getCharSignedness(comp: *const Compilation) std.builtin.Signedness {
        return comp.langopts.char_signedness_override orelse comp.target.cCharSignedness().?;
    }
};

// Target.float80Type
fn targetFloat80Type(target: *const std.Target) ?QualType {
    switch (target.cpu.arch) {
        .x86, .x86_64 => return .long_double,
        else => {},
    }
    return null;
}

// Target.hasInt128
fn targetHasInt128(target: *const std.Target) bool {
    if (target.cpu.arch == .wasm32) return true;
    if (target.cpu.arch == .x86_64) return true;
    return target.ptrBitWidth() >= 64;
}

// Target.intMaxType
fn targetIntMaxType(target: *const std.Target) QualType {
    switch (target.cpu.arch) {
        .aarch64,
        .aarch64_be,
        .sparc64,
        => {
            if (target.os.tag == .openbsd) return .long_long;
            if (target.os.tag == .windows) return .long_long;
            if (target.os.tag.isDarwin() and target.abi == .ilp32) return .long_long;
            return .long;
        },

        .bpfel,
        .bpfeb,
        .loongarch64,
        .riscv64,
        .powerpc64,
        .powerpc64le,
        .ve,
        => return .long,

        .x86_64 => switch (target.os.tag) {
            .windows, .openbsd, .uefi => {},
            else => switch (target.abi) {
                .gnux32,
                .muslx32,
                .x32,
                .gnuabin32,
                .muslabin32,
                .abin32,
                .ilp32,
                => {},
                else => return .long,
            },
        },

        .mips, .mipsel, .sparc => {}, // TODO

        else => {},
    }
    return .long_long;
}

// TypeStore.initNamedTypes: the wchar switch
fn wcharType(target: *const std.Target) QualType {
    const os = target.os.tag;
    const arch = target.cpu.arch;
    return switch (os) {
        .openbsd, .netbsd => .int,
        .ps4, .ps5 => .ushort,
        .uefi => .ushort,
        .windows => .ushort,
        .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => .int,
        else => switch (arch) {
            .aarch64, .aarch64_be => .uint,
            .arm, .armeb, .thumb, .thumbeb => .uint,
            .ve, .msp430 => .uint,
            .x86_64, .x86 => .int,
            .xcore => .uchar,
            else => .int,
        },
    };
}

/// A configuration string: `<triple>/<std>/<emulate>[/ms][/uchar|/schar]`.
fn makeComp(cfg: []const u8) !*Compilation {
    var it = mem.splitScalar(u8, cfg, '/');
    const triple = it.next().?;
    const std_name = it.next() orelse return error.BadConfig;
    const emulate_name = it.next() orelse return error.BadConfig;
    var langopts: LangOpts = .{
        .standard = std.meta.stringToEnum(Standard, std_name) orelse return error.BadStandard,
        .emulate = std.meta.stringToEnum(LangOpts.Compiler, emulate_name) orelse return error.BadEmulate,
    };
    while (it.next()) |opt| {
        if (mem.eql(u8, opt, "ms")) {
            langopts.ms_extensions = true;
        } else if (mem.eql(u8, opt, "uchar")) {
            langopts.char_signedness_override = .unsigned;
        } else if (mem.eql(u8, opt, "schar")) {
            langopts.char_signedness_override = .signed;
        } else return error.BadConfigOption;
    }
    const target = try parseTriple(triple);
    langopts.has_int24 = target.cpu.arch == .avr;

    const comp = try gpa.create(Compilation);
    comp.* = .{ .target = target, .langopts = langopts, .gpa = gpa };
    comp.type_store = .{
        .wchar = wcharType(&comp.target),
        .intmax = targetIntMaxType(&comp.target),
        .uint_least16_t = comp.intLeastN(16, .unsigned),
        .uint_least32_t = comp.intLeastN(32, .unsigned),
    };
    return comp;
}

/// Small triple parser (enough for the fixtures' and curated triples):
/// arch aliases, an optional vendor, os with optional version, optional abi.
fn parseTriple(triple: []const u8) !std.Target {
    var parts: [4][]const u8 = undefined;
    var n: usize = 0;
    var it = mem.splitScalar(u8, triple, '-');
    while (it.next()) |p| : (n += 1) {
        if (n == 4) return error.BadTriple;
        parts[n] = p;
    }
    if (n < 2) return error.BadTriple;
    const arch_name = parts[0];
    const arch: std.Target.Cpu.Arch = if (mem.eql(u8, arch_name, "arm64"))
        .aarch64
    else if (mem.eql(u8, arch_name, "i386") or mem.eql(u8, arch_name, "i686"))
        .x86
    else
        std.meta.stringToEnum(std.Target.Cpu.Arch, arch_name) orelse return error.BadArch;
    var i: usize = 1;
    const vendors = [_][]const u8{ "unknown", "pc", "apple", "none", "w64" };
    for (vendors) |v| {
        if (n >= 3 and mem.eql(u8, parts[1], v)) {
            i = 2;
            break;
        }
    }
    var os_name = parts[i];
    const os_end = mem.findAny(u8, os_name, "0123456789.") orelse os_name.len;
    os_name = os_name[0..os_end];
    const os_tag: std.Target.Os.Tag = if (mem.eql(u8, os_name, "darwin"))
        .macos
    else
        std.meta.stringToEnum(std.Target.Os.Tag, os_name) orelse return error.BadOs;
    const abi: std.Target.Abi = if (i + 1 < n) abi: {
        var abi_name = parts[i + 1];
        const abi_end = mem.findAny(u8, abi_name, "0123456789.") orelse abi_name.len;
        // keep gnueabihf etc. whole: only cut a trailing version
        if (std.meta.stringToEnum(std.Target.Abi, abi_name)) |a| break :abi a;
        abi_name = abi_name[0..abi_end];
        break :abi std.meta.stringToEnum(std.Target.Abi, abi_name) orelse return error.BadAbi;
    } else std.Target.Abi.default(arch, os_tag);
    const os = std.Target.Os.Tag.defaultVersionRange(os_tag, arch, abi);
    return .{
        .cpu = std.Target.Cpu.baseline(arch, os),
        .os = os,
        .abi = abi,
        .ofmt = std.Target.ObjectFormat.default(os_tag, arch),
    };
}

// ===========================================================================
// Diagnostics.formatArgs / templateIndex / formatString (verbatim)
// ===========================================================================

const Diagnostics = struct {
    pub fn formatArgs(w: *std.Io.Writer, fmt: []const u8, args: anytype) std.Io.Writer.Error!void {
        var i: usize = 0;
        inline for (comptime std.meta.fieldNames(@TypeOf(args))) |arg_name| {
            const arg = @field(args, arg_name);
            i += switch (@TypeOf(arg)) {
                []const u8 => try formatString(w, fmt[i..], arg),
                else => switch (@typeInfo(@TypeOf(arg))) {
                    .pointer => try formatString(w, fmt[i..], arg),
                    .@"struct" => try arg.format(w, fmt[i..]),
                    else => comptime unreachable,
                },
            };
        }
        try w.writeAll(fmt[i..]);
    }

    pub fn templateIndex(w: *std.Io.Writer, fmt: []const u8, template: []const u8) std.Io.Writer.Error!usize {
        const i = mem.find(u8, fmt, template) orelse {
            std.debug.panic("template `{s}` not found in format string `{s}`", .{ template, fmt });
        };
        try w.writeAll(fmt[0..i]);
        return i + template.len;
    }

    pub fn formatString(w: *std.Io.Writer, fmt: []const u8, str: []const u8) std.Io.Writer.Error!usize {
        const i = try templateIndex(w, fmt, "{s}");
        try w.writeAll(str);
        return i;
    }

    const Kind = enum { off, warning, @"error" };
};

/// Format a diagnostic's text (Zig `formatArgs` into an allocating writer).
fn formatDiag(fmt: []const u8, args: anytype) []const u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    Diagnostics.formatArgs(&aw.writer, fmt, args) catch @panic("oom");
    return aw.written();
}

/// The name of a Diagnostic constant (runtime lookup by fmt pointer, kind and option).
fn diagName(comptime D: type, d: D) []const u8 {
    inline for (comptime std.meta.declarations(D)) |decl_name| {
        if (@TypeOf(@field(D, decl_name)) == D) {
            const c: D = @field(D, decl_name);
            if (mem.eql(u8, c.fmt, d.fmt) and c.kind == d.kind and c.opt == d.opt) return decl_name;
        }
    }
    unreachable;
}

const Option = enum {
    @"c23-extensions",
    @"pre-c23-compat",
    @"c2y-extensions",
    @"pre-c2y-compat",
    @"deprecated-octal-literals",
    @"invalid-source-encoding",
    unicode,
    @"unknown-escape-sequence",
    @"four-char-constants",
    multichar,
    @"implicitly-unsigned-literal",
    @"gnu-imaginary-constant",
};

// ===========================================================================
// src/aro/Tokenizer/number_literal.zig (verbatim except `err`, see header)
// ===========================================================================

const number_literal = struct {
    pub const Prefix = enum(u8) {
        binary = 2,
        octal = 8,
        decimal = 10,
        hex = 16,

        pub fn digitAllowed(prefix: Prefix, c: u8) bool {
            return switch (c) {
                '0', '1' => true,
                '2'...'7' => prefix != .binary,
                '8'...'9' => prefix == .decimal or prefix == .hex,
                'a'...'f', 'A'...'F' => prefix == .hex,
                else => false,
            };
        }

        pub fn fromString(buf: []const u8, allow_msvc_extensions: bool) Prefix {
            if (buf.len == 1) return .decimal;
            // tokenizer enforces that first byte is a decimal digit or period
            switch (buf[0]) {
                '.', '1'...'9' => return .decimal,
                '0' => {},
                else => unreachable,
            }
            switch (buf[1]) {
                'x', 'X' => return if (buf.len == 2) .decimal else .hex,
                'b', 'B' => return if (buf.len == 2) .decimal else .binary,
                'o', 'O' => return if (buf.len == 2) .decimal else .octal,
                else => {
                    if (mem.findAny(u8, buf, "eE.")) |_| {
                        // This is a decimal floating point number that happens to start with zero
                        return .decimal;
                    } else if (Suffix.fromString(buf[1..], .int, allow_msvc_extensions)) |_| {
                        // This is `0` with a valid suffix
                        return .decimal;
                    } else {
                        return .octal;
                    }
                },
            }
        }

        /// Length of this prefix as a string
        pub fn stringLen(prefix: Prefix, buf: []const u8) usize {
            return switch (prefix) {
                .binary => 2,
                // Includes digit separator `'` in the prefix so that the first
                // character after the prefix is a digit.
                .octal => if (buf.len > 2 and
                    (buf[1] == 'o' or buf[1] == 'O' or buf[1] == '\'')) 2 else 1,
                .decimal => 0,
                .hex => 2,
            };
        }
    };

    pub const Suffix = enum {
        // zig fmt: off

        // int and imaginary int
        None, I,

        // unsigned real integers
        U, UL, ULL,

        // unsigned imaginary integers
        IU, IUL, IULL,

        // long or long double, real and imaginary
        L, IL,

        // long long and imaginary long long
        LL, ILL,

        // float and imaginary float
        F, IF,

        // _Float16 and imaginary _Float16
        F16, IF16,

        // __float80
        W,

        // Imaginary __float80
        IW,

        // _Float128
        Q, F128,

        // Imaginary _Float128
        IQ, IF128,

        // Imaginary _Bitint
        IWB, IUWB,

        // _Bitint
        WB, UWB,

        // __bf16
        BF16,

        // _Float32 and imaginary _Float32
        F32, IF32,

        // _Float64 and imaginary _Float64
        F64, IF64,

        // _Float32x and imaginary _Float32x
        F32x, IF32x,

        // _Float64x and imaginary _Float64x
        F64x, IF64x,

        // _Decimal32
        D32,

        // _Decimal64
        D64,

        // _Decimal128
        D128,

        // _Decimal64x
        D64x,

        // MSVC extensions
        I8,
        UI8,
        I16,
        UI16,
        I32,
        UI32,
        I64,
        UI64,

        // zig fmt: on

        const Tuple = struct { Suffix, []const []const u8 };

        const IntSuffixes = &[_]Tuple{
            .{ .U, &.{"U"} },
            .{ .L, &.{"L"} },
            .{ .WB, &.{"WB"} },
            .{ .UL, &.{ "U", "L" } },
            .{ .UWB, &.{ "U", "WB" } },
            .{ .LL, &.{"LL"} },
            .{ .ULL, &.{ "U", "LL" } },

            .{ .I8, &.{"I8"} },
            .{ .UI8, &.{"UI8"} },
            .{ .I16, &.{"I16"} },
            .{ .UI16, &.{"UI16"} },
            .{ .I32, &.{"I32"} },
            .{ .UI32, &.{"UI32"} },
            .{ .I64, &.{"I64"} },
            .{ .UI64, &.{"UI64"} },

            .{ .I, &.{"I"} },

            .{ .IWB, &.{ "I", "WB" } },
            .{ .IU, &.{ "I", "U" } },
            .{ .IL, &.{ "I", "L" } },
            .{ .IUL, &.{ "I", "U", "L" } },
            .{ .IUWB, &.{ "I", "U", "WB" } },
            .{ .ILL, &.{ "I", "LL" } },
            .{ .IULL, &.{ "I", "U", "LL" } },
        };

        const FloatSuffixes = &[_]Tuple{
            .{ .F16, &.{"F16"} },
            .{ .F, &.{"F"} },
            .{ .L, &.{"L"} },
            .{ .W, &.{"W"} },
            .{ .F128, &.{"F128"} },
            .{ .Q, &.{"Q"} },
            .{ .BF16, &.{"BF16"} },
            .{ .F32, &.{"F32"} },
            .{ .F64, &.{"F64"} },
            .{ .F32x, &.{"F32x"} },
            .{ .F64x, &.{"F64x"} },
            .{ .D32, &.{"D32"} },
            .{ .D64, &.{"D64"} },
            .{ .D128, &.{"D128"} },
            .{ .D64x, &.{"D64x"} },

            .{ .I, &.{"I"} },
            .{ .IL, &.{ "I", "L" } },
            .{ .IF16, &.{ "I", "F16" } },
            .{ .IF, &.{ "I", "F" } },
            .{ .IW, &.{ "I", "W" } },
            .{ .IF128, &.{ "I", "F128" } },
            .{ .IQ, &.{ "I", "Q" } },
            .{ .IF32, &.{ "I", "F32" } },
            .{ .IF64, &.{ "I", "F64" } },
            .{ .IF32x, &.{ "I", "F32x" } },
            .{ .IF64x, &.{ "I", "F64x" } },
        };

        pub fn fromString(buf: []const u8, suffix_kind: enum { int, float }, allow_msvc_extensions: bool) ?Suffix {
            if (buf.len == 0) return .None;

            const suffixes = switch (suffix_kind) {
                .float => FloatSuffixes,
                .int => IntSuffixes,
            };
            var scratch: [4]u8 = undefined;
            top: for (suffixes) |candidate| {
                const tag = candidate[0];
                const parts = candidate[1];
                var len: usize = 0;
                for (parts) |part| len += part.len;
                if (len != buf.len) continue;

                for (parts) |part| {
                    const lower = std.ascii.lowerString(&scratch, part);
                    if (mem.find(u8, buf, part) == null and mem.find(u8, buf, lower) == null) continue :top;
                }
                if (tag.isMSVCExtension() and !allow_msvc_extensions) continue;
                return tag;
            }
            return null;
        }

        pub fn isImaginary(suffix: Suffix) bool {
            return switch (suffix) {
                .I, .IL, .IF, .IU, .IUL, .ILL, .IULL, .IWB, .IUWB, .IF128, .IQ, .IW, .IF16, .IF32, .IF64, .IF32x, .IF64x => true,
                .None, .L, .F16, .F, .U, .UL, .LL, .ULL, .WB, .UWB, .F128, .Q, .W, .F32, .F64, .F32x, .F64x, .D32, .D64, .D128, .D64x, .BF16, .I8, .UI8, .I16, .UI16, .I32, .UI32, .I64, .UI64 => false,
            };
        }

        pub fn isSignedInteger(suffix: Suffix) bool {
            return switch (suffix) {
                .None, .L, .LL, .I, .IL, .ILL, .WB, .IWB, .I8, .I16, .I32, .I64 => true,
                .U, .UL, .ULL, .IU, .IUL, .IULL, .UWB, .IUWB, .UI8, .UI16, .UI32, .UI64 => false,
                .F, .IF, .F16, .F128, .IF128, .Q, .IQ, .W, .IW, .IF16, .F32, .IF32, .F64, .IF64, .F32x, .IF32x, .F64x, .IF64x, .D32, .D64, .D128, .D64x, .BF16 => unreachable,
            };
        }

        pub fn signedness(suffix: Suffix) std.builtin.Signedness {
            return if (suffix.isSignedInteger()) .signed else .unsigned;
        }

        pub fn isBitInt(suffix: Suffix) bool {
            return switch (suffix) {
                .WB, .UWB, .IWB, .IUWB => true,
                else => false,
            };
        }

        pub fn isFloat80(suffix: Suffix) bool {
            return suffix == .W or suffix == .IW;
        }

        pub fn isMSVCExtension(suffix: Suffix) bool {
            return switch (suffix) {
                .I8, .UI8, .I16, .UI16, .I32, .UI32, .I64, .UI64 => true,

                .None,
                .L,
                .F16,
                .F,
                .U,
                .UL,
                .LL,
                .ULL,
                .WB,
                .UWB,
                .F128,
                .Q,
                .W,
                .F32,
                .F64,
                .F32x,
                .F64x,
                .D32,
                .D64,
                .D128,
                .D64x,
                .BF16,
                .I,
                .IU,
                .IUL,
                .IULL,
                .IL,
                .ILL,
                .IF,
                .IF16,
                .IW,
                .IQ,
                .IF128,
                .IWB,
                .IUWB,
                .IF32,
                .IF32x,
                .IF64,
                .IF64x,
                => false,
            };
        }
    };

    pub const Parser = struct {
        comp: *Compilation,
        literal: []const u8,

        pub const Result = struct {
            bytes: []const u8,
            is_float: bool,
            prefix: Prefix,
            suffix: Suffix,
        };

        pub fn parse(p: *Parser) !Result {
            const buf = p.literal;
            const allow_fixed_size_int_suffixes = p.comp.langopts.allowFixedSizedIntSuffixes();
            const prefix = Prefix.fromString(buf, allow_fixed_size_int_suffixes);
            const prefix_len = prefix.stringLen(buf);
            const after_prefix = buf[prefix_len..];

            const int_part = try p.getIntegerPart(after_prefix, prefix);
            const after_int = after_prefix[int_part.len..];

            const frac = try p.getFracPart(after_int, prefix);
            const after_frac = after_int[frac.len..];

            const exponent = try p.getExponent(after_frac, prefix);
            const suffix_str = after_frac[exponent.len..];

            const is_float = (exponent.len > 0 or frac.len > 0);
            const suffix = Suffix.fromString(suffix_str, if (is_float) .float else .int, allow_fixed_size_int_suffixes) orelse {
                if (is_float) {
                    try p.err(.invalid_float_suffix, .{suffix_str});
                } else {
                    try p.err(.invalid_int_suffix, .{suffix_str});
                }
                return error.ParsingFailed;
            };
            if (suffix.isFloat80() and p.comp.float80Type() == null) {
                try p.err(.invalid_float_suffix, .{suffix_str});
                return error.ParsingFailed;
            }

            if (is_float) {
                assert(prefix == .hex or prefix == .decimal);
                if (prefix == .hex and exponent.len == 0) {
                    try p.err(.hex_floating_constant_requires_exponent, .{});
                    return error.ParsingFailed;
                }
                return .{
                    .bytes = buf[0 .. buf.len - suffix_str.len],
                    .is_float = true,
                    .prefix = prefix,
                    .suffix = suffix,
                };
            } else {
                const c23 = p.comp.langopts.standard.atLeast(.c23);
                if (prefix == .binary and !c23) {
                    try p.err(if (c23) .pre_c23_binary else .c23_binary, .{});
                }
                if (suffix.isBitInt()) {
                    try p.err(if (c23) .pre_c23_bitint else .bitint_suffix, .{});
                }
                if (prefix == .octal) {
                    const c2y = p.comp.langopts.standard.atLeast(.c2y);
                    if (prefix_len == 2 and buf[1] != '\'') {
                        try p.err(if (c2y) .pre_c2y_octal else .c2y_octal, .{});
                    } else if (c2y) {
                        try p.err(.c2y_deprecated_octal, .{});
                    }
                }
                return .{
                    .bytes = int_part,
                    .is_float = false,
                    .prefix = prefix,
                    .suffix = suffix,
                };
            }
        }

        const Diagnostic = struct {
            fmt: []const u8,
            kind: Diagnostics.Kind,
            opt: ?Option = null,
            extension: bool = false,

            pub const invalid_binary_digit: Diagnostic = .{
                .fmt = "invalid digit '{c}' in binary constant",
                .kind = .@"error",
            };

            pub const invalid_octal_digit: Diagnostic = .{
                .fmt = "invalid digit '{c}' in octal constant",
                .kind = .@"error",
            };

            pub const invalid_int_suffix: Diagnostic = .{
                .fmt = "invalid suffix '{s}' on integer constant",
                .kind = .@"error",
            };

            pub const invalid_float_suffix: Diagnostic = .{
                .fmt = "invalid suffix '{s}' on floating constant",
                .kind = .@"error",
            };

            pub const hex_floating_constant_requires_exponent: Diagnostic = .{
                .fmt = "hexadecimal floating constant requires an exponent",
                .kind = .@"error",
            };

            pub const exponent_has_no_digits: Diagnostic = .{
                .fmt = "exponent has no digits",
                .kind = .@"error",
            };

            pub const c23_binary: Diagnostic = .{
                .fmt = "binary integer literals are a C23 extension",
                .opt = .@"c23-extensions",
                .kind = .off,
                .extension = true,
            };

            pub const pre_c23_binary: Diagnostic = .{
                .fmt = "octal integer literals are incompatible with C standards before C23",
                .kind = .off,
                .opt = .@"pre-c23-compat",
            };

            pub const bitint_suffix: Diagnostic = .{
                .fmt = "'_BitInt' suffix for literals is a C23 extension",
                .opt = .@"c23-extensions",
                .kind = .warning,
                .extension = true,
            };

            pub const pre_c23_bitint: Diagnostic = .{
                .fmt = "'_BitInt' suffix for literals is incompatible with C standards before C23",
                .kind = .off,
                .opt = .@"pre-c23-compat",
            };

            pub const c2y_octal: Diagnostic = .{
                .fmt = "octal integer literals are a C2y extension",
                .opt = .@"c2y-extensions",
                .kind = .off,
                .extension = true,
            };

            pub const pre_c2y_octal: Diagnostic = .{
                .fmt = "octal integer literals are incompatible with C standards before C2y",
                .kind = .off,
                .opt = .@"pre-c2y-compat",
            };

            pub const c2y_deprecated_octal: Diagnostic = .{
                .fmt = "octal literals without a '0o' prefix are deprecated",
                .kind = .warning,
                .opt = .@"deprecated-octal-literals",
            };
        };

        // Probe: records instead of `effectiveKind` + `addWithLocation`.
        fn err(p: *Parser, diagnostic: Diagnostic, args: anytype) !void {
            p.comp.record(diagName(Diagnostic, diagnostic), 0, formatDiag(diagnostic.fmt, args));
        }

        fn getIntegerPart(p: *Parser, buf: []const u8, prefix: Prefix) ![]const u8 {
            if (buf[0] == '.') return "";

            if (!prefix.digitAllowed(buf[0])) {
                switch (prefix) {
                    .binary => try p.err(.invalid_binary_digit, .{text_literal.Ascii.init(buf[0])}),
                    .octal => try p.err(.invalid_octal_digit, .{text_literal.Ascii.init(buf[0])}),
                    .hex => try p.err(.invalid_int_suffix, .{buf}),
                    .decimal => unreachable,
                }
                return error.ParsingFailed;
            }

            for (buf, 0..) |c, idx| {
                if (idx == 0) continue;
                switch (c) {
                    '.' => return buf[0..idx],
                    'p', 'P' => return if (prefix == .hex) buf[0..idx] else {
                        try p.err(.invalid_int_suffix, .{buf[idx..]});
                        return error.ParsingFailed;
                    },
                    'e', 'E' => {
                        switch (prefix) {
                            .hex => continue,
                            .decimal => return buf[0..idx],
                            .binary => try p.err(.invalid_binary_digit, .{text_literal.Ascii.init(c)}),
                            .octal => try p.err(.invalid_octal_digit, .{text_literal.Ascii.init(c)}),
                        }
                        return error.ParsingFailed;
                    },
                    '0'...'9', 'a'...'d', 'A'...'D', 'f', 'F' => {
                        if (!prefix.digitAllowed(c)) {
                            switch (prefix) {
                                .binary => try p.err(.invalid_binary_digit, .{text_literal.Ascii.init(c)}),
                                .octal => try p.err(.invalid_octal_digit, .{text_literal.Ascii.init(c)}),
                                .decimal, .hex => try p.err(.invalid_int_suffix, .{buf[idx..]}),
                            }
                            return error.ParsingFailed;
                        }
                    },
                    '\'' => {},
                    else => return buf[0..idx],
                }
            }
            return buf;
        }

        fn getFracPart(p: *Parser, buf: []const u8, prefix: Prefix) ![]const u8 {
            if (buf.len == 0 or buf[0] != '.') return "";
            if (prefix == .binary or prefix == .octal) {
                try p.err(.invalid_int_suffix, .{buf});
                return error.ParsingFailed;
            }
            for (buf, 0..) |c, idx| {
                if (idx == 0) continue;
                if (c == '\'') continue;
                if (!prefix.digitAllowed(c)) return buf[0..idx];
            }
            return buf;
        }

        fn getExponent(p: *Parser, buf: []const u8, prefix: Prefix) ![]const u8 {
            if (buf.len == 0) return "";

            switch (buf[0]) {
                'e', 'E' => assert(prefix == .decimal),
                'p', 'P' => if (prefix != .hex) {
                    try p.err(.invalid_float_suffix, .{buf});
                    return error.ParsingFailed;
                },
                else => return "",
            }
            const end = for (buf, 0..) |c, idx| {
                if (idx == 0) continue;
                if (idx == 1 and (c == '+' or c == '-')) continue;
                switch (c) {
                    '0'...'9' => {},
                    '\'' => continue,
                    else => break idx,
                }
            } else buf.len;
            const exponent = buf[0..end];
            if (std.mem.findAny(u8, exponent, "0123456789") == null) {
                try p.err(.exponent_has_no_digits, .{});
                return error.ParsingFailed;
            }
            return exponent;
        }
    };
};

// ===========================================================================
// src/aro/Tokenizer/text_literal.zig (verbatim except `warn`, see header)
// ===========================================================================

const text_literal = struct {
    pub const Item = union(enum) {
        /// decoded hex or character escape
        value: u32,
        /// validated unicode codepoint
        codepoint: u21,
        /// Char literal in the source text is not utf8 encoded
        improperly_encoded: []const u8,
        /// 1 or more unescaped bytes
        utf8_text: std.unicode.Utf8View,
    };

    pub const Kind = enum {
        char,
        wide,
        utf_8,
        utf_16,
        utf_32,
        /// Error kind that halts parsing
        unterminated,

        /// Should only be called for string literals. Determines the result kind of two adjacent string
        /// literals
        pub fn concat(self: Kind, other: Kind) !Kind {
            if (self == .unterminated or other == .unterminated) return .unterminated;
            if (self == other) return self; // can always concat with own kind
            if (self == .char) return other; // char + X -> X
            if (other == .char) return self; // X + char -> X
            return error.CannotConcat;
        }

        /// Largest unicode codepoint that can be represented by this character kind
        /// May be smaller than the largest value that can be represented.
        /// For example u8 char literals may only specify 0-127 via literals or
        /// character escapes, but may specify up to \xFF via hex escapes.
        pub fn maxCodepoint(kind: Kind, comp: *const Compilation) u21 {
            return @intCast(switch (kind) {
                .char => std.math.maxInt(u7),
                .wide => @min(0x10FFFF, comp.wcharMax()),
                .utf_8 => std.math.maxInt(u7),
                .utf_16 => std.math.maxInt(u16),
                .utf_32 => 0x10FFFF,
                .unterminated => unreachable,
            });
        }

        /// Largest integer that can be represented by this character kind
        pub fn maxInt(kind: Kind, comp: *const Compilation) u32 {
            return @intCast(switch (kind) {
                .char, .utf_8 => std.math.maxInt(u8),
                .wide => comp.wcharMax(),
                .utf_16 => std.math.maxInt(u16),
                .utf_32 => std.math.maxInt(u32),
                .unterminated => unreachable,
            });
        }

        /// The C type of a character literal of this kind
        pub fn charLiteralType(kind: Kind, comp: *const Compilation) QualType {
            return switch (kind) {
                .char => .int,
                .wide => comp.type_store.wchar,
                .utf_8 => .uchar,
                .utf_16 => comp.type_store.uint_least16_t,
                .utf_32 => comp.type_store.uint_least32_t,
                .unterminated => unreachable,
            };
        }

        /// Return the actual contents of the literal with leading / trailing quotes and
        /// specifiers removed
        pub fn contentSlice(kind: Kind, delimited: []const u8) []const u8 {
            const end = delimited.len - 1; // remove trailing quote
            return switch (kind) {
                .char => delimited[1..end],
                .wide => delimited[2..end],
                .utf_8 => delimited[3..end],
                .utf_16 => delimited[2..end],
                .utf_32 => delimited[2..end],
                .unterminated => unreachable,
            };
        }

        /// The size of a character unit for a string literal of this kind
        pub fn charUnitSize(kind: Kind, comp: *const Compilation) Compilation.CharUnitSize {
            return switch (kind) {
                .char => .@"1",
                .wide => switch (comp.type_store.wchar.sizeof(comp)) {
                    2 => .@"2",
                    4 => .@"4",
                    else => unreachable,
                },
                .utf_8 => .@"1",
                .utf_16 => .@"2",
                .utf_32 => .@"4",
                .unterminated => unreachable,
            };
        }

        /// Required alignment within aro (on compiler host) for writing to Interner.strings.
        pub fn internalStorageAlignment(kind: Kind, comp: *const Compilation) usize {
            return switch (kind.charUnitSize(comp)) {
                inline else => |size| @alignOf(size.Type()),
            };
        }

        /// The C type of an element of a string literal of this kind
        pub fn elementType(kind: Kind, comp: *const Compilation) QualType {
            return switch (kind) {
                .unterminated => unreachable,
                .char => .char,
                .utf_8 => if (comp.langopts.hasChar8_T()) .uchar else .char,
                else => kind.charLiteralType(comp),
            };
        }
    };

    pub const Ascii = struct {
        val: u7,

        pub fn init(val: anytype) Ascii {
            // Probe: Zig's safety-checked @intCast panics for val > 0x7F.
            if (val > 0x7F) {
                zigUnreachable("Ascii.init: @intCast to u7");
                return .{ .val = @truncate(val) };
            }
            return .{ .val = @intCast(val) };
        }

        pub fn format(ctx: Ascii, w: *std.Io.Writer, fmt: []const u8) !usize {
            const i = try Diagnostics.templateIndex(w, fmt, "{c}");
            if (std.ascii.isPrint(ctx.val)) {
                try w.writeByte(ctx.val);
            } else {
                try w.print("x{x:0>2}", .{ctx.val});
            }
            return i;
        }
    };

    pub const Parser = struct {
        comp: *Compilation,
        literal: []const u8,
        i: usize = 0,
        kind: Kind,
        max_codepoint: u21,
        /// Offset added to `loc.byte_offset` when emitting an error.
        offset: u32 = 0,
        /// We only want to issue a max of 1 error per char literal
        errored: bool = false,
        /// Makes incorrect encoding always an error.
        /// Used when concatenating string literals.
        incorrect_encoding_is_error: bool = false,
        /// If this is false, do not issue any diagnostics for incorrect character encoding
        /// Incorrect encoding is allowed if we are unescaping an identifier in the preprocessor
        diagnose_incorrect_encoding: bool = true,

        pub const Result = union(enum) {
            unsigned: u32,
            signed: i32,
        };

        pub fn parse(p: *Parser) !Result {
            if (p.kind == .utf_8 and !p.comp.langopts.standard.atLeast(.c23)) {
                try p.warn(.u8_char_lit, .{});
            }
            var val: u32 = 0;

            const gpa_ = p.comp.gpa;
            var is_multichar = false;
            if (p.literal.len == 1 and std.ascii.isAscii(p.literal[0])) {
                // fast path: single unescaped ASCII char
                val = p.literal[0];
            } else {
                const max_chars_expected = 4;
                var bfa_buf: [max_chars_expected]u32 = undefined;
                var bfa: std.heap.BufferFirstAllocator = .init(@ptrCast(&bfa_buf), gpa_);
                const allocator = bfa.allocator();
                var chars: std.ArrayList(u32) = .empty;
                defer chars.deinit(allocator);

                chars.ensureUnusedCapacity(allocator, max_chars_expected) catch unreachable; // stack allocation already succeeded

                while (try p.next()) |item| switch (item) {
                    .value => |v| try chars.append(allocator, v),
                    .codepoint => |c| try chars.append(allocator, c),
                    .improperly_encoded => |s| {
                        try chars.ensureUnusedCapacity(allocator, s.len);
                        for (s) |c| chars.appendAssumeCapacity(c);
                    },
                    .utf8_text => |view| {
                        var it = view.iterator();
                        var max_codepoint_seen: u21 = 0;
                        try chars.ensureUnusedCapacity(allocator, view.bytes.len);
                        while (it.nextCodepoint()) |c| {
                            max_codepoint_seen = @max(max_codepoint_seen, c);
                            chars.appendAssumeCapacity(c);
                        }
                        if (max_codepoint_seen > p.max_codepoint) {
                            try p.err(.char_too_large, .{});
                        }
                    },
                };

                is_multichar = chars.items.len > 1;
                if (is_multichar) {
                    if (p.kind == .char and chars.items.len == 4) {
                        try p.warn(.four_char_char_literal, .{});
                    } else if (p.kind == .char) {
                        try p.warn(.multichar_literal_warning, .{});
                    } else {
                        const kind: []const u8 = switch (p.kind) {
                            .wide => "wide",
                            .utf_8, .utf_16, .utf_32 => "Unicode",
                            else => unreachable,
                        };
                        try p.err(.invalid_multichar_literal, .{kind});
                    }
                }

                var multichar_overflow = false;
                if (p.kind == .char and is_multichar) {
                    for (chars.items) |item| {
                        val, const overflowed = @shlWithOverflow(val, 8);
                        multichar_overflow = multichar_overflow or overflowed != 0;
                        val += @as(u8, @truncate(item));
                    }
                } else if (chars.items.len > 0) {
                    val = chars.items[chars.items.len - 1];
                }

                if (multichar_overflow) {
                    try p.err(.char_lit_too_wide, .{});
                }
            }

            // C99 6.4.4.4.10
            // > If an integer character constant contains a single character or escape sequence,
            // > its value is the one that results when an object with type char whose value is
            // > that of the single character or escape sequence is converted to type int.
            // This conversion only matters if `char` is signed and has a high-order bit of `1`
            if (p.kind == .char and !is_multichar and val > 0x7F and p.comp.getCharSignedness() == .signed) {
                // Probe: Zig's safety-checked @intCast panics for val > 0xFF.
                if (val > 0xFF) zigUnreachable("text_literal.Parser.parse: @intCast to u8");
                const signed: i8 = @bitCast(@as(u8, @truncate(val)));
                return .{ .signed = signed };
            }
            return .{ .unsigned = val };
        }

        fn prefixLen(self: *const Parser) usize {
            return switch (self.kind) {
                .unterminated => unreachable,
                .char => 0,
                .utf_8 => 2,
                .wide, .utf_16, .utf_32 => 1,
            };
        }

        const Diagnostic = struct {
            fmt: []const u8,
            kind: Diagnostics.Kind,
            opt: ?Option = null,
            extension: bool = false,

            pub const illegal_char_encoding_error: Diagnostic = .{
                .fmt = "illegal character encoding in character literal",
                .kind = .@"error",
            };

            pub const illegal_char_encoding_warning: Diagnostic = .{
                .fmt = "illegal character encoding in character literal",
                .kind = .warning,
                .opt = .@"invalid-source-encoding",
            };

            pub const missing_hex_escape: Diagnostic = .{
                .fmt = "\\{c} used with no following hex digits",
                .kind = .@"error",
            };

            pub const escape_sequence_overflow: Diagnostic = .{
                .fmt = "escape sequence out of range",
                .kind = .@"error",
            };

            pub const incomplete_universal_character: Diagnostic = .{
                .fmt = "incomplete universal character name",
                .kind = .@"error",
            };

            pub const invalid_universal_character: Diagnostic = .{
                .fmt = "invalid universal character",
                .kind = .@"error",
            };

            pub const char_too_large: Diagnostic = .{
                .fmt = "character too large for enclosing character literal type",
                .kind = .@"error",
            };

            pub const ucn_basic_char_error: Diagnostic = .{
                .fmt = "character '{c}' cannot be specified by a universal character name",
                .kind = .@"error",
            };

            pub const ucn_basic_char_warning: Diagnostic = .{
                .fmt = "specifying character '{c}' with a universal character name is incompatible with C standards before C23",
                .kind = .off,
                .opt = .@"pre-c23-compat",
            };

            pub const ucn_control_char_error: Diagnostic = .{
                .fmt = "universal character name refers to a control character",
                .kind = .@"error",
            };

            pub const ucn_control_char_warning: Diagnostic = .{
                .fmt = "universal character name referring to a control character is incompatible with C standards before C23",
                .kind = .off,
                .opt = .@"pre-c23-compat",
            };

            pub const c89_ucn_in_literal: Diagnostic = .{
                .fmt = "universal character names are only valid in C99 or later",
                .kind = .warning,
                .opt = .unicode,
            };

            pub const non_standard_escape_char: Diagnostic = .{
                .fmt = "use of non-standard escape character '\\{c}'",
                .kind = .off,
                .extension = true,
            };

            pub const unknown_escape_sequence: Diagnostic = .{
                .fmt = "unknown escape sequence '\\{c}'",
                .kind = .warning,
                .opt = .@"unknown-escape-sequence",
            };

            pub const four_char_char_literal: Diagnostic = .{
                .fmt = "multi-character character constant",
                .opt = .@"four-char-constants",
                .kind = .off,
            };

            pub const multichar_literal_warning: Diagnostic = .{
                .fmt = "multi-character character constant",
                .kind = .warning,
                .opt = .multichar,
            };

            pub const invalid_multichar_literal: Diagnostic = .{
                .fmt = "{s} character literals may not contain multiple characters",
                .kind = .@"error",
            };

            pub const char_lit_too_wide: Diagnostic = .{
                .fmt = "character constant too long for its type",
                .kind = .warning,
            };

            pub const u8_char_lit: Diagnostic = .{
                .fmt = "UTF-8 character literal is a C23 extension",
                .opt = .@"c23-extensions",
                .kind = .warning,
                .extension = true,
            };
        };

        pub fn err(p: *Parser, diagnostic: Diagnostic, args: anytype) !void {
            defer p.offset = 0;
            if (p.errored) return;
            defer p.errored = true;
            try p.warn(diagnostic, args);
        }

        // Probe: records instead of `effectiveKind` + `addWithLocation`.
        pub fn warn(p: *Parser, diagnostic: Diagnostic, args: anytype) error{OutOfMemory}!void {
            defer p.offset = 0;
            if (p.errored) return;
            p.comp.record(diagName(Diagnostic, diagnostic), p.offset, formatDiag(diagnostic.fmt, args));
        }

        pub fn next(p: *Parser) !?Item {
            if (p.i >= p.literal.len) return null;

            const start = p.i;
            if (p.literal[start] != '\\') {
                p.i = mem.findScalarPos(u8, p.literal, start + 1, '\\') orelse p.literal.len;
                const unescaped_slice = p.literal[start..p.i];

                const view = std.unicode.Utf8View.init(unescaped_slice) catch {
                    if (!p.diagnose_incorrect_encoding) {
                        return .{ .improperly_encoded = p.literal[start..p.i] };
                    }
                    if (p.incorrect_encoding_is_error) {
                        try p.warn(.illegal_char_encoding_error, .{});
                        return .{ .improperly_encoded = p.literal[start..p.i] };
                    }
                    if (p.kind != .char) {
                        try p.err(.illegal_char_encoding_error, .{});
                        return null;
                    }
                    try p.warn(.illegal_char_encoding_warning, .{});
                    return .{ .improperly_encoded = p.literal[start..p.i] };
                };
                return .{ .utf8_text = view };
            }
            switch (p.literal[start + 1]) {
                'u', 'U' => return try p.parseUnicodeEscape(),
                else => return try p.parseEscapedChar(),
            }
        }

        fn parseUnicodeEscape(p: *Parser) !?Item {
            const start = p.i;

            std.debug.assert(p.literal[p.i] == '\\');

            const kind = p.literal[p.i + 1];
            std.debug.assert(kind == 'u' or kind == 'U');

            p.i += 2;
            if (p.i >= p.literal.len or !std.ascii.isHex(p.literal[p.i])) {
                try p.err(.missing_hex_escape, .{Ascii.init(kind)});
                return null;
            }
            const expected_len: usize = if (kind == 'u') 4 else 8;
            var overflowed = false;
            var count: usize = 0;
            var val: u32 = 0;

            for (p.literal[p.i..], 0..) |c, i| {
                if (i == expected_len) break;

                const char = std.fmt.charToDigit(c, 16) catch break;

                val, const overflow = @shlWithOverflow(val, 4);
                overflowed = overflowed or overflow != 0;
                val |= char;
                count += 1;
            }
            p.i += expected_len;

            if (overflowed) {
                p.offset += @intCast(start + p.prefixLen());
                try p.err(.escape_sequence_overflow, .{});
                return null;
            }

            if (count != expected_len) {
                try p.err(.incomplete_universal_character, .{});
                return null;
            }

            if (val > std.math.maxInt(u21) or !std.unicode.utf8ValidCodepoint(@intCast(val))) {
                p.offset += @intCast(start + p.prefixLen());
                try p.err(.invalid_universal_character, .{});
                return null;
            }

            if (val > p.max_codepoint) {
                try p.err(.char_too_large, .{});
                return null;
            }

            if (val < 0xA0 and (val != '$' and val != '@' and val != '`')) {
                const is_error = !p.comp.langopts.standard.atLeast(.c23);
                if (val >= 0x20 and val <= 0x7F) {
                    if (is_error) {
                        try p.err(.ucn_basic_char_error, .{Ascii.init(val)});
                    } else if (!p.comp.langopts.standard.atLeast(.c23)) {
                        try p.warn(.ucn_basic_char_warning, .{Ascii.init(val)});
                    }
                } else {
                    if (is_error) {
                        try p.err(.ucn_control_char_error, .{});
                    } else if (!p.comp.langopts.standard.atLeast(.c23)) {
                        try p.warn(.ucn_control_char_warning, .{});
                    }
                }
            }

            if (!p.comp.langopts.standard.atLeast(.c99)) try p.warn(.c89_ucn_in_literal, .{});
            return .{ .codepoint = @intCast(val) };
        }

        fn parseEscapedChar(p: *Parser) !Item {
            p.i += 1;
            const c = p.literal[p.i];
            defer if (c != 'x' and (c < '0' or c > '7')) {
                p.i += 1;
            };

            switch (c) {
                '\n' => unreachable, // removed by line splicing
                '\r' => unreachable, // removed by line splicing
                '\'', '\"', '\\', '?' => return .{ .value = c },
                'n' => return .{ .value = '\n' },
                'r' => return .{ .value = '\r' },
                't' => return .{ .value = '\t' },
                'a' => return .{ .value = 0x07 },
                'b' => return .{ .value = 0x08 },
                'e', 'E' => {
                    p.offset += @intCast(p.i);
                    try p.warn(.non_standard_escape_char, .{Ascii.init(c)});
                    return .{ .value = 0x1B };
                },
                '(', '{', '[', '%' => {
                    p.offset += @intCast(p.i);
                    try p.warn(.non_standard_escape_char, .{Ascii.init(c)});
                    return .{ .value = c };
                },
                'f' => return .{ .value = 0x0C },
                'v' => return .{ .value = 0x0B },
                'x' => return .{ .value = try p.parseNumberEscape(.hex) },
                '0'...'7' => return .{ .value = try p.parseNumberEscape(.octal) },
                'u', 'U' => unreachable, // handled by parseUnicodeEscape
                else => {
                    p.offset += @intCast(p.i);
                    try p.warn(.unknown_escape_sequence, .{Ascii.init(c)});
                    return .{ .value = c };
                },
            }
        }

        fn parseNumberEscape(p: *Parser, base: EscapeBase) !u32 {
            var val: u32 = 0;
            var count: usize = 0;
            var overflowed = false;
            const start = p.i;
            defer p.i += count;

            const slice = switch (base) {
                .octal => p.literal[p.i..@min(p.literal.len, p.i + 3)], // max 3 chars
                .hex => blk: {
                    p.i += 1;
                    break :blk p.literal[p.i..]; // skip over 'x'; could have an arbitrary number of chars
                },
            };
            for (slice) |c| {
                const char = std.fmt.charToDigit(c, @backingInt(base)) catch break;
                val, const overflow = @shlWithOverflow(val, base.log2());
                if (overflow != 0) overflowed = true;
                val += char;
                count += 1;
            }
            if (overflowed or val > p.kind.maxInt(p.comp)) {
                p.offset += @intCast(start + p.prefixLen());
                try p.err(.escape_sequence_overflow, .{});
                return 0;
            }
            if (count == 0) {
                std.debug.assert(base == .hex);
                try p.err(.missing_hex_escape, .{Ascii.init('x')});
            }
            return val;
        }
    };

    const EscapeBase = enum(u8) {
        octal = 8,
        hex = 16,

        fn log2(base: EscapeBase) u4 {
            return switch (base) {
                .octal => 3,
                .hex => 4,
            };
        }
    };
};

// ===========================================================================
// Values
// ===========================================================================

const FloatVal = union(enum) {
    f16: f16,
    f32: f32,
    f64: f64,
    f80: f80,
    f128: f128,

    fn fromF128(bits: u64, x: f128) FloatVal {
        return switch (bits) {
            16 => .{ .f16 = @floatCast(x) },
            32 => .{ .f32 = @floatCast(x) },
            64 => .{ .f64 = @floatCast(x) },
            80 => .{ .f80 = @floatCast(x) },
            128 => .{ .f128 = x },
            else => unreachable,
        };
    }

    /// std.fmt.parseFloat directly at the target width (one rounding).
    fn direct(bits: u64, s: []const u8) FloatVal {
        return switch (bits) {
            16 => .{ .f16 = std.fmt.parseFloat(f16, s) catch unreachable },
            32 => .{ .f32 = std.fmt.parseFloat(f32, s) catch unreachable },
            64 => .{ .f64 = std.fmt.parseFloat(f64, s) catch unreachable },
            80 => .{ .f80 = std.fmt.parseFloat(f80, s) catch unreachable },
            128 => .{ .f128 = std.fmt.parseFloat(f128, s) catch unreachable },
            else => unreachable,
        };
    }

    fn eqlBits(a: FloatVal, b: FloatVal) bool {
        return switch (a) {
            .f16 => |x| @as(u16, @bitCast(x)) == @as(u16, @bitCast(b.f16)),
            .f32 => |x| @as(u32, @bitCast(x)) == @as(u32, @bitCast(b.f32)),
            .f64 => |x| @as(u64, @bitCast(x)) == @as(u64, @bitCast(b.f64)),
            .f80 => |x| @as(u80, @bitCast(x)) == @as(u80, @bitCast(b.f80)),
            .f128 => |x| @as(u128, @bitCast(x)) == @as(u128, @bitCast(b.f128)),
        };
    }

    fn zeroLike(v: FloatVal) FloatVal {
        return switch (v) {
            inline else => |_, tag| @unionInit(FloatVal, @tagName(tag), 0.0),
        };
    }

    pub fn format(v: FloatVal, w: *std.Io.Writer) !void {
        switch (v) {
            .f16 => |x| try w.print("f16:0x{x:0>4}", .{@as(u16, @bitCast(x))}),
            .f32 => |x| try w.print("f32:0x{x:0>8}", .{@as(u32, @bitCast(x))}),
            .f64 => |x| try w.print("f64:0x{x:0>16}", .{@as(u64, @bitCast(x))}),
            .f80 => |x| try w.print("f80:0x{x:0>20}", .{@as(u80, @bitCast(x))}),
            .f128 => |x| try w.print("f128:0x{x:0>32}", .{@as(u128, @bitCast(x))}),
        }
    }

    /// Value.print float arm (used only to cross-check AST dump values).
    fn printAst(v: FloatVal, w: *std.Io.Writer) !void {
        const x: f64 = switch (v) {
            .f16 => |x| @round(@as(f64, x) * 1000) / 1000,
            .f32 => |x| @round(@as(f64, x) * 1000000) / 1000000,
            .f64 => |x| x,
            .f80 => |x| @floatCast(x),
            .f128 => |x| @floatCast(x),
        };
        try w.print("{d}", .{x});
    }
};

const Value = union(enum) {
    none,
    int: big.int.Const,
    float: FloatVal,
    complex: [2]FloatVal,

    pub fn format(v: Value, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (v) {
            .none => try w.writeAll("none"),
            .int => |c| try writeInt(w, c),
            .float => |f| try f.format(w),
            .complex => |c| {
                try w.writeAll("c");
                try c[0].format(w);
                try w.writeAll(":");
                const s = fmtAlloc("{f}", .{c[1]});
                try w.writeAll(s[mem.findScalar(u8, s, ':').? + 1 ..]);
            },
        }
    }
};

fn writeInt(w: *std.Io.Writer, c: big.int.Const) std.Io.Writer.Error!void {
    if (!c.positive and !c.eqlZero()) try w.writeAll("-");
    try w.writeAll("0x");
    const s = c.abs().toStringAlloc(gpa, 16, .lower) catch @panic("oom");
    try w.writeAll(s);
}

/// Value.int
fn intValue(x: anytype) Value {
    var m = big.int.Managed.initSet(gpa, x) catch @panic("oom");
    return .{ .int = m.toConst() };
}

/// Value.maxInt (twosCompIntLimit .max) for int types of at most 128 bits.
fn maxIntU128(qt: QualType, comp: *const Compilation) u128 {
    const bits: u7 = @intCast(qt.bitSizeof(comp) - 1);
    const signed = qt.signedness(comp) == .signed;
    const top: u128 = @as(u128, 1) << bits;
    return if (signed) top - 1 else top - 1 + top;
}

/// Value.intCast (value part).
fn intCast(v: Value, dest_ty: QualType, comp: *const Compilation) Value {
    const c = v.int;
    const dest_bits: usize = @intCast(dest_ty.bitSizeof(comp));
    const limbs = gpa.alloc(big.Limb, big.int.calcTwosCompLimbCount(@max(c.bitCountTwosComp(), dest_bits))) catch @panic("oom");
    var result_bigint = big.int.Mutable{ .limbs = limbs, .positive = undefined, .len = undefined };
    result_bigint.truncate(c, dest_ty.signedness(comp), dest_bits);
    return .{ .int = result_bigint.toConst() };
}

// ===========================================================================
// src/aro/Parser.zig literal value logic (without AST nodes)
// ===========================================================================

const ParserDiag = struct {
    fmt: []const u8,
    kind: Diagnostics.Kind,
    opt: ?Option = null,
    extension: bool = false,

    // Parser.Diagnostic / Preprocessor.Diagnostic constants used here
    pub const int_literal_too_big: ParserDiag = .{
        .fmt = "integer literal is too large to be represented in any integer type",
        .kind = .@"error",
    };
    pub const implicitly_unsigned_literal: ParserDiag = .{
        .fmt = "integer literal is too large to be represented in a signed integer type, interpreting as unsigned",
        .kind = .warning,
        .opt = .@"implicitly-unsigned-literal",
        .extension = true,
    };
    pub const gnu_imaginary_constant: ParserDiag = .{
        .fmt = "imaginary constants are a GNU extension",
        .kind = .off,
        .opt = .@"gnu-imaginary-constant",
        .extension = true,
    };
    pub const float_literal_in_expr: ParserDiag = .{
        .fmt = "floating point literal in preprocessor expression",
        .kind = .@"error",
    };
    pub const unsupported_str_cat: ParserDiag = .{
        .fmt = "unsupported string literal concatenation",
        .kind = .@"error",
    };
    pub const empty_char_literal_error: ParserDiag = .{
        .fmt = "empty character constant",
        .kind = .@"error",
    };
    pub const unterminated_char_literal_error: ParserDiag = .{
        .fmt = "missing terminating ' character",
        .kind = .@"error",
    };
};

const P = struct {
    comp: *Compilation,

    /// Parser.err(tok_i, ...): recorded at the token, offset 0.
    fn err(p: *P, tok_i: u32, d: ParserDiag, args: anytype) !void {
        const saved = p.comp.cur_tok;
        p.comp.cur_tok = tok_i;
        defer p.comp.cur_tok = saved;
        p.comp.record(diagName(ParserDiag, d), 0, formatDiag(d.fmt, args));
    }

    const Result = struct {
        qt: QualType = .int,
        val: Value = .none,
        /// the int_literal / float_literal node (differs from qt/val for imaginary literals)
        literal_qt: QualType = .int,
        literal_val: Value = .none,
    };

    fn getMSVCIntSuffixType(p: *P, bits: enum { @"8", @"16", @"32", @"64" }, signedness: std.builtin.Signedness) QualType {
        return switch (bits) {
            .@"8" => if (signedness == .signed) .char else .uchar,
            .@"16" => p.comp.intLeastN(16, signedness),
            .@"32" => p.comp.intLeastN(32, signedness),
            .@"64" => if (p.comp.langopts.emulate != .msvc) p.comp.smallestNBitIntTargetIndependent(64, signedness) else if (signedness == .signed) .long_long else .ulong_long,
        };
    }

    fn parseFloat(p: *P, buf: []const u8, suffix: number_literal.Suffix, tok_i: u32) !Result {
        const qt: QualType = switch (suffix) {
            .None, .I => .double,
            .F, .IF => .float,
            .F16, .IF16 => .float16,
            .BF16 => .bf16,
            .L, .IL => .long_double,
            .W, .IW => p.comp.float80Type().?,
            .Q, .IQ, .F128, .IF128 => .float128,
            .F32, .IF32 => .float32,
            .F64, .IF64 => .float64,
            .F32x, .IF32x => .float32x,
            .F64x, .IF64x => .float64x,
            .D32 => .dfloat32,
            .D64 => .dfloat64,
            .D128 => .dfloat128,
            .D64x => .dfloat64x,
            else => unreachable,
        };
        const val: Value = key: {
            var strings: std.ArrayList(u8) = .empty;
            for (buf) |c| {
                if (c != '\'') try strings.append(gpa, c);
            }

            const float = std.fmt.parseFloat(f128, strings.items) catch {
                zigUnreachable("parseFloat: std.fmt.parseFloat(f128) failed (catch unreachable)");
                return error.ZigUnreachable;
            };
            const fv = FloatVal.fromF128(qt.bitSizeof(p.comp), float);
            // Probe only: tag results where one direct rounding would differ.
            if (!fv.eqlBits(FloatVal.direct(qt.bitSizeof(p.comp), strings.items))) dbl_round = true;
            break :key .{ .float = fv };
        };
        var res: Result = .{ .qt = qt, .val = val, .literal_qt = qt, .literal_val = val };
        if (suffix.isImaginary()) {
            try p.err(tok_i, .gnu_imaginary_constant, .{});
            res.qt = try qt.toComplex(p.comp);
            res.val = .{ .complex = .{ val.float.zeroLike(), val.float } };
        }
        return res;
    }

    fn fixedSizeInt(p: *P, base: u8, buf: []const u8, suffix: number_literal.Suffix, tok_i: u32) !Result {
        var val: u64 = 0;
        var overflow = false;
        for (buf) |c| {
            const digit: u64 = switch (c) {
                '0'...'9' => c - '0',
                'A'...'Z' => c - 'A' + 10,
                'a'...'z' => c - 'a' + 10,
                '\'' => continue,
                else => unreachable,
            };

            if (val != 0) {
                const product, const overflowed = @mulWithOverflow(val, base);
                if (overflowed != 0) {
                    overflow = true;
                }
                val = product;
            }
            const sum, const overflowed = @addWithOverflow(val, digit);
            if (overflowed != 0) overflow = true;
            val = sum;
        }
        var res: Result = .{
            .val = intValue(val),
        };
        if (overflow) {
            try p.err(tok_i, .int_literal_too_big, .{});
            res.qt = .ulong_long;
            return res;
        }
        if (suffix.isSignedInteger() and base == 10) {
            const max_int = maxIntU128(p.comp.type_store.intmax, p.comp);
            if (val > max_int) {
                try p.err(tok_i, .implicitly_unsigned_literal, .{});
            }
        }

        const qts: []const QualType = if (suffix.signedness() == .unsigned)
            &.{ .uint, .ulong, .ulong_long }
        else if (base == 10)
            &.{ .int, .long, .long_long }
        else
            &.{ .int, .uint, .long, .ulong, .long_long, .ulong_long };

        const suffix_qt: QualType = switch (suffix) {
            .None, .I => .int,
            .U, .IU => .uint,
            .UL, .IUL => .ulong,
            .ULL, .IULL => .ulong_long,
            .L, .IL => .long,
            .LL, .ILL => .long_long,
            .I8 => p.getMSVCIntSuffixType(.@"8", .signed),
            .UI8 => p.getMSVCIntSuffixType(.@"8", .unsigned),
            .I16 => p.getMSVCIntSuffixType(.@"16", .signed),
            .UI16 => p.getMSVCIntSuffixType(.@"16", .unsigned),
            .I32 => p.getMSVCIntSuffixType(.@"32", .signed),
            .UI32 => p.getMSVCIntSuffixType(.@"32", .unsigned),
            .I64 => p.getMSVCIntSuffixType(.@"64", .signed),
            .UI64 => p.getMSVCIntSuffixType(.@"64", .unsigned),
            else => unreachable,
        };

        if (suffix.isMSVCExtension()) {
            res.qt = suffix_qt; // No type promotion for MSVC suffixes
            res.val = intCast(res.val, suffix_qt, p.comp); // No diagnostic for truncation or sign change for MSVC exact-width types
        } else {
            for (qts) |qt| {
                res.qt = qt;
                if (res.qt.intRankOrder(suffix_qt, p.comp).compare(.lt)) continue;
                const max_int = maxIntU128(res.qt, p.comp);
                if (val <= max_int) break;
            } else switch (p.comp.langopts.emulate) {
                .no, .gcc => if (targetHasInt128(&p.comp.target)) {
                    res.qt = .int128;
                } else {
                    res.qt = .long_long;
                },
                .msvc, .clang => res.qt = .ulong_long,
            }
        }
        return res;
    }

    fn parseInt(p: *P, prefix: number_literal.Prefix, buf: []const u8, suffix: number_literal.Suffix, tok_i: u32) !Result {
        const base = @backingInt(prefix);
        var res = if (suffix.isBitInt())
            try p.bitInt(base, buf, suffix, tok_i)
        else
            try p.fixedSizeInt(base, buf, suffix, tok_i);
        res.literal_qt = res.qt;
        res.literal_val = res.val;

        if (suffix.isImaginary()) {
            try p.err(tok_i, .gnu_imaginary_constant, .{});
            res.qt = try res.qt.toComplex(p.comp);
            res.val = .none;
        }
        return res;
    }

    fn bitInt(_: *P, base: u8, buf: []const u8, suffix: number_literal.Suffix, tok_i: u32) !Result {
        _ = tok_i;
        var managed = try big.int.Managed.init(gpa);
        {
            var strings: std.ArrayList(u8) = .empty;
            for (buf) |c| {
                if (c != '\'') try strings.append(gpa, c);
            }
            managed.setString(base, strings.items) catch |e| switch (e) {
                error.InvalidBase => unreachable, // `base` is one of 2, 8, 10, 16
                error.InvalidCharacter => unreachable, // digits validated by Tokenizer
                else => |er| return er,
            };
        }
        const c = managed.toConst();
        const bits_needed: u16 = blk: {
            // Literal `0` requires at least 1 bit
            const count = @max(1, c.bitCountTwosComp());
            // The wb suffix results in a _BitInt that includes space for the sign bit even if the
            // value of the constant is positive or was specified in hexadecimal or octal notation.
            const sign_bits = @intFromBool(suffix.isSignedInteger());
            const bits_needed = count + sign_bits;
            // Zig: @intCast to IntFittingRange(0, bit_int_max_bits) (65535)
            if (bits_needed > 65535) {
                zigUnreachable("bitInt: @intCast of bits_needed to IntFittingRange(0, 65535)");
                return error.ZigUnreachable;
            }
            break :blk @intCast(bits_needed);
        };
        return .{
            .val = .{ .int = c },
            .qt = .{ .tag = .bit_int, .bits = bits_needed, .sign = suffix.signedness() },
        };
    }

    /// Parser.parseNumberToken
    pub fn parseNumberToken(p: *P, literal: []const u8) !Result {
        var number_literal_parser: number_literal.Parser = .{
            .comp = p.comp,
            .literal = literal,
        };
        const parsed = try number_literal_parser.parse();

        if (parsed.is_float) {
            return p.parseFloat(parsed.bytes, parsed.suffix, 0);
        } else {
            return p.parseInt(parsed.prefix, parsed.bytes, parsed.suffix, 0);
        }
    }

    const CharResult = struct {
        kind: text_literal.Kind,
        qt: QualType,
        parsed: text_literal.Parser.Result,
    };

    /// Parser.charLiteral (tok_id given by the probe's classifier)
    fn charLiteral(p: *P, tok_id: TokId, tok: []const u8) !CharResult {
        const char_kind = tok_id.classifyChar() orelse {
            if (tok_id == .empty_char_literal) {
                try p.err(0, .empty_char_literal_error, .{});
            } else if (tok_id == .unterminated_char_literal) {
                try p.err(0, .unterminated_char_literal_error, .{});
            } else unreachable;
            return .{ .kind = .char, .qt = .int, .parsed = .{ .unsigned = 0 } };
        };

        var char_literal_parser: text_literal.Parser = .{
            .comp = p.comp,
            .literal = char_kind.contentSlice(tok),
            .kind = char_kind,
            .max_codepoint = char_kind.maxCodepoint(p.comp),
        };
        const parsed = try char_literal_parser.parse();
        return .{ .kind = char_kind, .qt = char_kind.charLiteralType(p.comp), .parsed = parsed };
    }

    const StringResult = union(enum) {
        ok: struct { kind: text_literal.Kind, unit: u32, qt: QualType, bytes: []const u8 },
        cannot_concat: u32,
        unterminated: u32,
        failed,
    };

    /// Parser.stringLiteral over a run of tokens
    fn stringLiteral(p: *P, ids: []const TokId, toks: []const []const u8) !StringResult {
        var string_end: usize = 0;
        var string_kind: text_literal.Kind = .char;
        while (string_end < ids.len) : (string_end += 1) {
            const next = ids[string_end].classifyString().?;
            string_kind = string_kind.concat(next) catch {
                try p.err(@intCast(string_end), .unsupported_str_cat, .{});
                return .{ .cannot_concat = @intCast(string_end) };
            };
            if (string_kind == .unterminated) {
                // Diagnostic issued in preprocessor.
                return .{ .unterminated = @intCast(string_end) };
            }
        }
        const count = string_end;
        assert(count > 0);

        const char_width = string_kind.charUnitSize(p.comp);

        var strings: std.ArrayList(u8) = .empty;
        for (toks, ids, 0..) |tok, id, tok_i| {
            p.comp.cur_tok = @intCast(tok_i);
            const this_kind = id.classifyString().?;
            const slice = this_kind.contentSlice(tok);
            var char_literal_parser: text_literal.Parser = .{
                .comp = p.comp,
                .literal = slice,
                .kind = this_kind,
                .max_codepoint = 0x10ffff,
                .incorrect_encoding_is_error = count > 1,
            };

            while (try char_literal_parser.next()) |item| switch (item) {
                .value => |v| {
                    switch (char_width) {
                        .@"1" => try strings.append(gpa, @intCast(v)),
                        .@"2" => {
                            const word: u16 = @intCast(v);
                            try strings.appendSlice(gpa, mem.asBytes(&word));
                        },
                        .@"4" => try strings.appendSlice(gpa, mem.asBytes(&v)),
                    }
                },
                .codepoint => |c| {
                    switch (char_width) {
                        .@"1" => {
                            var buf: [4]u8 = undefined;
                            const written = std.unicode.utf8Encode(c, &buf) catch unreachable;
                            const encoded = buf[0..written];
                            try strings.appendSlice(gpa, encoded);
                        },
                        .@"2" => {
                            var utf16_buf: [2]u16 = undefined;
                            var utf8_buf: [4]u8 = undefined;
                            const utf8_written = std.unicode.utf8Encode(c, &utf8_buf) catch unreachable;
                            const utf16_written = std.unicode.utf8ToUtf16Le(&utf16_buf, utf8_buf[0..utf8_written]) catch unreachable;
                            const bytes = std.mem.sliceAsBytes(utf16_buf[0..utf16_written]);
                            try strings.appendSlice(gpa, bytes);
                        },
                        .@"4" => {
                            const val: u32 = c;
                            try strings.appendSlice(gpa, mem.asBytes(&val));
                        },
                    }
                },
                .improperly_encoded => |bytes| {
                    if (count > 1) {
                        return .failed;
                    }
                    try strings.appendSlice(gpa, bytes);
                },
                .utf8_text => |view| {
                    switch (char_width) {
                        .@"1" => try strings.appendSlice(gpa, view.bytes),
                        .@"2" => {
                            const dest = try gpa.alloc(u16, view.bytes.len);
                            const words_written = std.unicode.utf8ToUtf16Le(dest, view.bytes) catch unreachable;
                            try strings.appendSlice(gpa, std.mem.sliceAsBytes(dest[0..words_written]));
                        },
                        .@"4" => {
                            var it = view.iterator();
                            while (it.nextCodepoint()) |codepoint| {
                                const val: u32 = codepoint;
                                try strings.appendSlice(gpa, mem.asBytes(&val));
                            }
                        },
                    }
                },
            };
        }
        try strings.appendNTimes(gpa, 0, @backingInt(char_width));
        const slice = strings.items;

        return .{ .ok = .{
            .kind = string_kind,
            .unit = @backingInt(char_width),
            .qt = .{ .tag = .array, .elem = string_kind.elementType(p.comp).t_int, .len = @divExact(slice.len, @backingInt(char_width)) },
            .bytes = slice,
        } };
    }
};

// ---------------------------------------------------------------------------
// Preprocessor/Parser.zig primaryExpr (.pp_num, char literals)

const PpResult = union(enum) {
    failed,
    rejected,
    signed: i64,
    unsigned: u64,
};

fn ppNum(p: *P, literal: []const u8) !PpResult {
    const intmax = i64;
    const uintmax = u64;
    var number_literal_parser: number_literal.Parser = .{
        .comp = p.comp,
        .literal = literal,
    };
    const parsed = number_literal_parser.parse() catch |e| switch (e) {
        error.ParsingFailed => return .failed,
        else => |er| return er,
    };
    if (parsed.is_float or parsed.suffix.isImaginary()) {
        try p.err(0, .float_literal_in_expr, .{});
        return .rejected;
    }

    const base = @backingInt(parsed.prefix);
    var val: uintmax = 0;
    var overflow = false;
    for (parsed.bytes) |c| {
        const digit: uintmax = switch (c) {
            '0'...'9' => c - '0',
            'A'...'Z' => c - 'A' + 10,
            'a'...'z' => c - 'a' + 10,
            '\'' => continue,
            else => unreachable,
        };

        if (val != 0) {
            const product, const overflowed = @mulWithOverflow(val, base);
            if (overflowed != 0) {
                overflow = true;
            }
            val = product;
        }
        const sum, const overflowed = @addWithOverflow(val, digit);
        if (overflowed != 0) overflow = true;
        val = sum;
    }
    if (overflow) {
        try p.err(0, .int_literal_too_big, .{});
    }
    const max_int = std.math.maxInt(intmax);
    if (val > max_int) {
        if (parsed.suffix.isSignedInteger() and base == 10) {
            try p.err(0, .implicitly_unsigned_literal, .{});
        }
        return .{ .unsigned = val };
    }
    if (parsed.suffix.isSignedInteger()) {
        return .{ .signed = @intCast(val) };
    } else {
        return .{ .unsigned = val };
    }
}

fn ppChar(p: *P, tok_id: TokId, tok: []const u8) !PpResult {
    const char_kind = tok_id.classifyChar().?;
    const comp = p.comp;

    var char_literal_parser: text_literal.Parser = .{
        .comp = comp,
        .literal = char_kind.contentSlice(tok),
        .kind = char_kind,
        .max_codepoint = char_kind.maxCodepoint(comp),
    };
    const parsed = try char_literal_parser.parse();
    const unsigned = switch (parsed) {
        .signed => |s| return .{ .signed = s },
        .unsigned => |u| u,
    };

    const char_literal_qt = char_kind.charLiteralType(comp);
    if (char_literal_qt.signedness(comp) == .unsigned or
        (char_kind == .char and comp.getCharSignedness() == .unsigned))
    {
        return .{ .unsigned = unsigned };
    } else {
        return .{ .signed = unsigned };
    }
}

/// Preprocessor.unescapeUcn decoding loop (extended identifiers with UCNs)
fn unescapeUcn(comp: *Compilation, identifier: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var identifier_parser: text_literal.Parser = .{
        .comp = comp,
        .literal = identifier,
        .kind = .utf_8,
        .max_codepoint = 0x10ffff,
        .diagnose_incorrect_encoding = false,
    };
    while (try identifier_parser.next()) |decoded| {
        switch (decoded) {
            .value => unreachable, // validated by tokenizer
            .codepoint => |c| {
                var buf: [4]u8 = undefined;
                const written = std.unicode.utf8Encode(c, &buf) catch unreachable;
                try out.appendSlice(gpa, buf[0..written]);
            },
            .improperly_encoded => |bytes| try out.appendSlice(gpa, bytes),
            .utf8_text => |view| try out.appendSlice(gpa, view.bytes),
        }
    }
    return out.items;
}

// ---------------------------------------------------------------------------
// Token ids from a token's spelling (what the Tokenizer would produce)

const TokId = enum {
    string_literal,
    string_literal_utf_8,
    string_literal_utf_16,
    string_literal_utf_32,
    string_literal_wide,
    unterminated_string_literal,
    char_literal,
    char_literal_utf_8,
    char_literal_utf_16,
    char_literal_utf_32,
    char_literal_wide,
    empty_char_literal,
    unterminated_char_literal,

    fn classifyString(id: TokId) ?text_literal.Kind {
        return switch (id) {
            .string_literal => .char,
            .string_literal_utf_8 => .utf_8,
            .string_literal_wide => .wide,
            .string_literal_utf_16 => .utf_16,
            .string_literal_utf_32 => .utf_32,
            .unterminated_string_literal => .unterminated,
            else => null,
        };
    }

    fn classifyChar(id: TokId) ?text_literal.Kind {
        return switch (id) {
            .char_literal => .char,
            .char_literal_utf_8 => .utf_8,
            .char_literal_wide => .wide,
            .char_literal_utf_16 => .utf_16,
            .char_literal_utf_32 => .utf_32,
            else => null,
        };
    }

    fn of(tok: []const u8) TokId {
        var plen: usize = 0;
        var k: enum { char, utf8, u16, u32, wide } = .char;
        if (mem.startsWith(u8, tok, "u8")) {
            plen = 2;
            k = .utf8;
        } else if (tok[0] == 'u') {
            plen = 1;
            k = .u16;
        } else if (tok[0] == 'U') {
            plen = 1;
            k = .u32;
        } else if (tok[0] == 'L') {
            plen = 1;
            k = .wide;
        }
        const q = tok[plen];
        const body = tok[plen + 1 ..];
        // terminated iff the last byte is an unescaped closing quote
        var terminated = false;
        var i: usize = 0;
        while (i < body.len) : (i += 1) {
            if (body[i] == '\\') {
                i += 1;
                continue;
            }
            if (body[i] == q) {
                terminated = i == body.len - 1;
                break;
            }
        }
        if (q == '"') {
            if (!terminated) return .unterminated_string_literal;
            return switch (k) {
                .char => .string_literal,
                .utf8 => .string_literal_utf_8,
                .u16 => .string_literal_utf_16,
                .u32 => .string_literal_utf_32,
                .wide => .string_literal_wide,
            };
        }
        if (!terminated) return .unterminated_char_literal;
        if (body.len == 1) return .empty_char_literal;
        return switch (k) {
            .char => .char_literal,
            .utf8 => .char_literal_utf_8,
            .u16 => .char_literal_utf_16,
            .u32 => .char_literal_utf_32,
            .wide => .char_literal_wide,
        };
    }
};

// ===========================================================================
// Output
// ===========================================================================

const prov = "zig-0.17.0-port";
const prov_dblround = "zig-0.17.0-port-dblround";

const Out = struct {
    w: *std.Io.Writer,
    count: usize = 0,

    fn comment(o: *Out, comptime fmt: []const u8, args: anytype) void {
        o.w.print("# " ++ fmt ++ "\n", args) catch @panic("write");
    }
};

/// Percent-encode a field (README "Encoding"): bytes outside 0x21..0x7E, '%'
/// and '|' become %XX; with `space`, 0x20 is kept (diagnostic text).
fn pct(w: *std.Io.Writer, s: []const u8, space: bool) !void {
    for (s) |b| {
        if (((b >= 0x21 and b <= 0x7E) or (space and b == 0x20)) and b != '%' and b != '|') {
            try w.writeByte(b);
        } else {
            try w.print("%{X:0>2}", .{b});
        }
    }
}

fn pctAlloc(s: []const u8, space: bool) []const u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    pct(&aw.writer, s, space) catch @panic("oom");
    return aw.written();
}

fn hexBytes(w: *std.Io.Writer, s: []const u8) !void {
    if (s.len == 0) return w.writeAll("-");
    for (s) |b| try w.print("{x:0>2}", .{b});
}

fn writeDiags(w: *std.Io.Writer, comp: *Compilation) !void {
    for (comp.diags.items) |d| {
        try w.print(" | {s} {d}:{d} ", .{ d.name, d.tok, d.offset });
        try pct(w, d.text, true);
    }
}

fn reset(comp: *Compilation) void {
    comp.diags = .empty;
    comp.cur_tok = 0;
    zig_unreachable = null;
    dbl_round = false;
    active_comp = comp;
}

/// Write one vector: `head = result prov | diags`, or `head = unreachable ...`
/// (preceded by a `# zig-unreachable:` comment) when the copied Zig code hit
/// safety-checked illegal behaviour.
fn finish(w: *std.Io.Writer, head: []const u8, result: []const u8, comp: *Compilation) !void {
    if (zig_unreachable) |why| {
        comp.diags.items.len = unreachable_diags;
        try w.print("# zig-unreachable: {s}\n{s} = unreachable {s}", .{ why, head, prov });
    } else {
        try w.print("{s} = {s} {s}", .{ head, result, if (dbl_round) prov_dblround else prov });
    }
    try writeDiags(w, comp);
    try w.writeAll("\n");
}

fn head1(op: []const u8, cfg: []const u8, input: []const u8) []const u8 {
    return fmtAlloc("{s} {s} {s}", .{ op, cfg, pctAlloc(input, false) });
}

// ---- number ---------------------------------------------------------------

fn numberLine(w: *std.Io.Writer, cfg: []const u8, lit: []const u8) !void {
    const comp = try makeComp(cfg);
    reset(comp);
    var p: P = .{ .comp = comp };
    const head = head1("number", cfg, lit);
    // syntax result from a scratch Compilation, so diagnostics are recorded once
    const syn_comp = try makeComp(cfg);
    var syn: number_literal.Parser = .{ .comp = syn_comp, .literal = lit };
    const parsed = syn.parse() catch {
        _ = p.parseNumberToken(lit) catch {};
        return finish(w, head, "fail", comp);
    };
    const res = p.parseNumberToken(lit) catch |e| switch (e) {
        error.ZigUnreachable => return finish(w, head, "", comp),
        else => return e,
    };
    try finish(w, head, fmtAlloc("{s} {s} {s} {f} {f} {f} {f}", .{
        @tagName(parsed.prefix), @tagName(parsed.suffix), pctAlloc(parsed.bytes, false),
        res.qt,                  res.val,                 res.literal_qt,
        res.literal_val,
    }), comp);
}

fn ppNumberLine(w: *std.Io.Writer, cfg: []const u8, lit: []const u8) !void {
    const comp = try makeComp(cfg);
    reset(comp);
    var p: P = .{ .comp = comp };
    const r = try ppNum(&p, lit);
    try finish(w, head1("pp_number", cfg, lit), ppText(r), comp);
}

fn ppText(r: PpResult) []const u8 {
    return switch (r) {
        .failed => "fail",
        .rejected => "rejected",
        .signed => |s| if (s < 0) fmtAlloc("signed -0x{x}", .{@as(u64, @intCast(-@as(i128, s)))}) else fmtAlloc("signed 0x{x}", .{s}),
        .unsigned => |u| fmtAlloc("unsigned 0x{x}", .{u}),
    };
}

// ---- char -------------------------------------------------------------------

fn charLine(w: *std.Io.Writer, cfg: []const u8, tok: []const u8) !void {
    const comp = try makeComp(cfg);
    reset(comp);
    var p: P = .{ .comp = comp };
    const r = try p.charLiteral(TokId.of(tok), tok);
    const v = switch (r.parsed) {
        .signed => |s| if (s < 0) fmtAlloc("signed -0x{x}", .{@as(u32, @intCast(-@as(i64, s)))}) else fmtAlloc("signed 0x{x}", .{s}),
        .unsigned => |u| fmtAlloc("unsigned 0x{x}", .{u}),
    };
    try finish(w, head1("char", cfg, tok), fmtAlloc("{s} {f} {s}", .{ @tagName(r.kind), r.qt, v }), comp);
}

fn ppCharLine(w: *std.Io.Writer, cfg: []const u8, tok: []const u8) !bool {
    const id = TokId.of(tok);
    if (id.classifyChar() == null) return false;
    const comp = try makeComp(cfg);
    reset(comp);
    var p: P = .{ .comp = comp };
    const r = try ppChar(&p, id, tok);
    try finish(w, head1("pp_char", cfg, tok), ppText(r), comp);
    return true;
}

// ---- string -----------------------------------------------------------------

fn stringLine(w: *std.Io.Writer, cfg: []const u8, toks: []const []const u8) !void {
    const comp = try makeComp(cfg);
    reset(comp);
    var p: P = .{ .comp = comp };
    const ids = try gpa.alloc(TokId, toks.len);
    for (toks, ids) |t, *id| id.* = TokId.of(t);
    const r = try p.stringLiteral(ids, toks);
    var hw: std.Io.Writer.Allocating = .init(gpa);
    try hw.writer.print("string {s} {d}", .{ cfg, toks.len });
    for (toks) |t| {
        try hw.writer.writeAll(" ");
        try pct(&hw.writer, t, false);
    }
    const result = switch (r) {
        .ok => |s| ok: {
            var rw: std.Io.Writer.Allocating = .init(gpa);
            try rw.writer.print("{s} {d} {f} ", .{ @tagName(s.kind), s.unit, s.qt });
            try hexBytes(&rw.writer, s.bytes);
            break :ok rw.written();
        },
        .cannot_concat => |i| fmtAlloc("cannot_concat {d}", .{i}),
        .unterminated => |i| fmtAlloc("unterminated {d}", .{i}),
        .failed => "fail",
    };
    try finish(w, hw.written(), result, comp);
}

fn ucnIdentLine(w: *std.Io.Writer, cfg: []const u8, ident: []const u8) !void {
    const comp = try makeComp(cfg);
    reset(comp);
    const bytes = try unescapeUcn(comp, ident);
    var rw: std.Io.Writer.Allocating = .init(gpa);
    try hexBytes(&rw.writer, bytes);
    try finish(w, head1("ucn_ident", cfg, ident), rw.written(), comp);
}

// ===========================================================================
// Curated inputs
// ===========================================================================

const cfg_main = "x86_64-linux-gnu/default/gcc";

/// Number configurations. Each literal group lists the ones it runs under.
const cfgs_std = [_][]const u8{
    "x86_64-linux-gnu/c89/gcc",
    "x86_64-linux-gnu/c17/gcc",
    cfg_main,
    "x86_64-linux-gnu/c23/gcc",
    "x86_64-linux-gnu/c2y/gcc",
};
const cfgs_emulate = [_][]const u8{
    cfg_main,
    "x86_64-linux-gnu/default/clang",
    "x86_64-linux-gnu/default/clang/ms",
    "x86_64-linux-gnu/default/no",
    "x86_64-windows-msvc/default/msvc/ms",
};
const cfgs_targets = [_][]const u8{
    cfg_main,
    "i386-linux-gnu/default/gcc",
    "aarch64-linux-gnu/default/gcc",
    "arm-linux-gnueabihf/default/gcc",
    "x86_64-windows-msvc/default/msvc/ms",
    "x86_64-windows-gnu/default/gcc",
    "riscv64-linux-gnu/default/gcc",
    "avr-freestanding-none/default/gcc",
    "msp430-freestanding-none/default/gcc",
};
const cfgs_text = [_][]const u8{
    cfg_main,
    "x86_64-linux-gnu/c89/gcc",
    "x86_64-linux-gnu/c99/gcc",
    "x86_64-linux-gnu/c23/gcc",
    "aarch64-linux-gnu/default/gcc",
    "x86_64-windows-msvc/default/msvc/ms",
    "avr-freestanding-none/default/gcc",
    "msp430-freestanding-none/default/gcc",
};
const cfgs_text_main = [_][]const u8{
    cfg_main,
    "x86_64-linux-gnu/c23/gcc",
};
const cfgs_all = cfgs_targets ++ [_][]const u8{
    "x86_64-linux-gnu/c23/gcc",
    "x86_64-linux-gnu/default/clang",
    "x86_64-linux-gnu/default/gcc/uchar",
    "aarch64-macos-none/default/clang",
};

const Group = struct {
    title: []const u8,
    cfgs: []const []const u8,
    items: []const []const u8,
};

const number_groups = [_]Group{
    .{ .title = "prefixes, digits and separators", .cfgs = &.{cfg_main}, .items = &.{
        "0",           "1",       "00",     "07",      "08",      "09",      "0x",       "0X",
        "0b",          "0B",      "0o",     "0O",      "0x1",     "0X1F",    "0xabcdef", "0xABCDEF",
        "0b101",       "0B11",    "0b2",    "0b12",    "0b1e",    "0b1.0",   "0b1p",     "0b1'0",
        "0b'1",        "0o17",    "0O7",    "0o8",     "0o9",     "0o1.0",   "0o1e",     "0'7",
        "0'8",         "0'",      "017",    "019",     "078",     "0128",    "07.5",     "08.5",
        "09e1",        "0e",      "0e1",    "0e+",     "1'000",   "1''2",    "1'",       "0x'FF",
        "0xF'F",       "0xg",     "0x1g",   "0x1.",    "0x1.0",   "0x.8p0",  "0x1p",     "0x1p+",
        "0x1p-",       "0x1p3",   "0x1P-3", "0x1.8p1", "0x1.p-2", "0xep1",   "0xe",      "0x1e",
        "0x1e+1",      "0xE+0xC", "0x12.e", "0x1.0e",  "0x.p1",   "0x1'0p0", "0x1p1'0",  "1e",
        "1e+",         "1e-",     "1e'1",   "1E+5",    "1e-5",    "1e10",    "1.",       ".5",
        ".5e",         "1.e5",    "1'e5",   "1.ep-1",  "1.pp-1",  "1p3",     "1p",       "1.5E+3L",
        "1'000.000'1", "1e1'0",   "0.5",    "00.5",    "1.0e+'5", "123LLuf", "1x",       "1a",
        "1f",          "1d",      "1_000",  "1.0_f",   "0x1p0_",
    } },
    .{ .title = "integer suffixes", .cfgs = &.{ cfg_main, "x86_64-linux-gnu/default/clang/ms" }, .items = &.{
        "1u",   "1U",    "1l",    "1L",    "1ll",   "1LL",   "1lL",  "1Ll",   "1ul",    "1lu",
        "1Ul",  "1uL",   "1LU",   "1ull",  "1llu",  "1LLU",  "1uLL", "1ulL",  "1uu",    "1lul",
        "1lll", "1wb",   "1WB",   "1uwb",  "1wbu",  "1UWB",  "1Wb",  "1wB",   "1i",     "1I",
        "1j",   "1iu",   "1ui",   "1il",   "1li",   "1ill",  "1lli", "1iull", "1llui",  "1iwb",
        "1wbi", "1iuwb", "1ii",   "1i8",   "1I8",   "1i16",  "1i32", "1i64",  "1ui8",   "1Ui8",
        "1UI8", "1ui16", "1ui32", "1ui64", "1UI64", "1i128", "1u8",  "0x1u",  "0x1ull", "0xfull",
        "0b1u", "0b1wb", "017u",  "017i",  "0u",    "0i8",   "0wb",  "0uwb",  "0lu",    "0x1i64",
    } },
    .{ .title = "float suffixes", .cfgs = &.{ cfg_main, "x86_64-linux-gnu/default/clang", "aarch64-linux-gnu/default/gcc", "x86_64-windows-msvc/default/msvc/ms" }, .items = &.{
        "1.0f",    "1.0F",    "1.0l",     "1.0L",    "1.0w",    "1.0W",     "1.0q",     "1.0Q",
        "1.0f16",  "1.0F16",  "1.0bf16",  "1.0BF16", "1.0Bf16", "1.0bF16",  "1.0f32",   "1.0F32",
        "1.0f64",  "1.0f128", "1.0F128",  "1.0f32x", "1.0F32x", "1.0f32X",  "1.0f64x",  "1.0f128x",
        "1.0d32",  "1.0D32",  "1.0d64",   "1.0d128", "1.0d64x", "1.0dd",    "1.0df",    "1.0i",
        "1.0j",    "1.0if",   "1.0fi",    "1.0il",   "1.0li",   "1.0iw",    "1.0wi",    "1.0iq",
        "1.0if16", "1.0f16i", "1.0if128", "1.0if32", "1.0if64", "1.0if32x", "1.0if64x", "1.0id32",
        "1.0ii",   "1.0u",    "1.0ul",    "1.0ll",   "1.0fl",   "1.0ff",    "1e3f",     "1e3i",
        "0x1p0f",  "0x1p0l",  "0x1p0q",   "0x1p0w",  "0x1p0if", "1.0bf16i", "1.0ibf16", "1.0wb",
    } },
    .{ .title = "standard gates (binary, octal, _BitInt)", .cfgs = &cfgs_std, .items = &.{
        "0b101", "0B1", "0b1u", "0o17", "0O17", "0'17", "017", "00", "0", "0x10", "1wb", "1uwb", "0b1wb", "0o7wb", "07wb", "1iwb",
    } },
    .{ .title = "integer types and overflow", .cfgs = &cfgs_targets, .items = &.{
        "32767",                               "32768",                          "65535",                   "65536",
        "2147483647",                          "2147483648",                     "4294967295",              "4294967296",
        "9223372036854775807",                 "9223372036854775808",            "18446744073709551615",    "18446744073709551616",
        "99999999999999999999",                "123456789012345678901234567890", "0x7FFF",                  "0x8000",
        "0xFFFF",                              "0x10000",                        "0x7FFFFFFF",              "0x80000000",
        "0xFFFFFFFF",                          "0x100000000",                    "0x7FFFFFFFFFFFFFFF",      "0x8000000000000000",
        "0xFFFFFFFFFFFFFFFF",                  "0x10000000000000000",            "0x1FFFFFFFFFFFFFFFF",     "037777777777",
        "040000000000",                        "01777777777777777777777",        "02000000000000000000000", "0b11111111111111111111111111111111",
        "0b100000000000000000000000000000000", "2147483648u",                    "2147483648l",             "2147483648ll",
        "4294967296u",                         "9223372036854775808u",           "9223372036854775808l",    "9223372036854775808ll",
        "9223372036854775808ull",              "18446744073709551615l",          "18446744073709551615ll",  "18446744073709551616u",
        "0x8000000000000000l",                 "0xFFFFFFFFul",                   "0xFFFFFFFFFFFFFFFFll",    "0xFFFFFFFFu",
        "0xFFFFFFFFl",                         "65535u",                         "65536u",                  "32768l",
        "4294967295l",                         "1844'6744'0737'0955'1615",       "0x1'0000'0000'0000'0000",
    } },
    .{ .title = "_BitInt literals", .cfgs = &.{ cfg_main, "x86_64-linux-gnu/c23/gcc", "i386-linux-gnu/default/gcc" }, .items = &.{
        "0wb",   "0uwb",  "1wb",   "1uwb", "127wb", "128wb", "255uwb",                  "256uwb",                 "0x7Fwb",                                     "0x80wb",                                    "0xFFwb",                                        "0xFFuwb",
        "0b1wb", "017wb", "1'2wb", "1iwb", "1iuwb", "1uiwb", "18446744073709551615uwb", "18446744073709551616wb", "340282366920938463463374607431768211455uwb", "340282366920938463463374607431768211456wb", "0x1'0000'0000'0000'0000'0000'0000'0000'0000wb", "115792089237316195423570985008687907853269984665640564039457584007913129639935uwb",
    } },
    .{ .title = "imaginary integers", .cfgs = &.{ cfg_main, "i386-linux-gnu/default/gcc" }, .items = &.{
        "1i", "1ui", "1il", "1ill", "1iull", "4294967296i", "0x80000000i", "18446744073709551616i",
    } },
    .{ .title = "MSVC fixed-size suffixes", .cfgs = &.{ "x86_64-windows-msvc/default/msvc/ms", "x86_64-linux-gnu/default/clang/ms", "aarch64-linux-gnu/default/clang/ms", "i386-linux-gnu/default/clang/ms", "avr-freestanding-none/default/gcc", "avr-freestanding-none/default/clang/ms", "aarch64-macos-none/default/clang/ms" }, .items = &.{
        "0i8",                     "127i8",                    "128i8",                   "255i8",     "256i8",         "255ui8",         "256ui8",        "0x80i8",
        "32767i16",                "32768i16",                 "65535ui16",               "65536ui16", "4294967295i32", "4294967296ui32", "2147483648i32", "9223372036854775808i64",
        "18446744073709551615i64", "18446744073709551615ui64", "18446744073709551616i64", "1I64",      "1Ui64",         "1i64u",          "1i8i",
    } },
    .{ .title = "float values and rounding (all widths)", .cfgs = &cfgs_targets, .items = &.{
        "0.0",                                                                                               "1.0",                                                     "0.1",                                                                                                                  "0.1f",                        "0.1L",                                                                                              "0.1q",                                                                "0.1f16",                                                                                                                  "0.1bf16",                                     "0.1f32",                                                                                       "0.1f64",
        "0.1f32x",                                                                                           "0.1f64x",                                                 "0.1d32",                                                                                                               "0.1d64",                      "0.1d128",                                                                                           "0.1d64x",                                                             "0.1w",                                                                                                                    "1e309",                                       "1e309f",                                                                                       "1e39f",
        "1e4933L",                                                                                           "1e4933q",                                                 "1e-400",                                                                                                               "1e-46f",                      "1e-5000L",                                                                                          "1e-5000q",                                                            "65504.0f16",                                                                                                              "65520.0f16",                                  "3.4028234663852886e38f",                                                                       "3.4028235677973366e38f",
        "3.40282357e38f",                                                                                    "0x1.fffffep127f",                                         "0x1.ffffffp127f",                                                                                                      "0x1.fffffefp127f",            "0x1.fffffffffffffp1023",                                                                            "0x1.fffffffffffff8p1023",                                             "0x1.fffffffffffff7ffp1023",                                                                                               "0x1p-1074",                                   "0x1p-1075",                                                                                    "0x1.8p-1075",
        "0x1p-149f",                                                                                         "0x1p-150f",                                               "0x1.000002p-150f",                                                                                                     "0x1p-16445L",                 "0x1p-16446L",                                                                                       "0x1.8p-16446L",                                                       "0x1p-16494q",                                                                                                             "0x1p-16495q",                                 "0x1.0000000000000000000000000001p-16495q",                                                     "0x1.fffffffffffffffep16383L",
        "0x1.ffffffffffffffffp16383L",                                                                       "0x1.0000000000000001p0L",                                 "0x1.0000000000000003p0L",                                                                                              "0x1.00000000000000018p0L",    "0x1.ffffffffffffffffffffffffffff8p0q",                                                              "0x1.ffffffffffffffffffffffffffff7p0q",                                "1.18973149535723176502e+4932L",                                                                                           "1.18973149535723176508575932662800702e4932q", "3.36210314311209350626e-4932L",                                                                "3.64519953188247460252840593361941982e-4951L",
        "6.47517511943802511092443895822764655e-4966q",                                                      "2.2250738585072011e-308",                                 "2.2250738585072012e-308",                                                                                              "4.9406564584124654e-324",     "2.4703282292062327e-324",                                                                           "2.4703282292062328e-324",                                             "1.7976931348623157e308",                                                                                                  "1.7976931348623158e308",                      "1.7976931348623159e308",                                                                       "0.30000000000000000000000000000000000000001",
        "123456789012345678901234567890.0",                                                                  "1.00000000000000011102230246251565404236316680908203125", "1.000000000000000111022302462515654042363166809082031250000000000000000000000000000000000000000000000000000000000001", "1.000000059604644775390625f", "1.0000000596046447753906250000000000000000000000000000000000000000000000000000000000000000000001f", "1.0000000000000000000542101086242752217003726400434970855712890625L", "1.00000000000000000005421010862427522170037264004349708557128906250000000000000000000000000000000000000000000000000001L", "1.00048828125f16",                            "1.000488281250000000000000000000000000000000000000000000000000000000000000000000000000001f16", "1.00390625bf16",
        "1.0039062500000000000000000000000000000000000000000000000000000000000000000000000000000000001bf16", "1'000.000'1",                                             "0x1'0p0",                                                                                                              "0x.8p1",                      "0X1.8P+1L",
    } },
    .{ .title = "imaginary floats", .cfgs = &.{ cfg_main, "aarch64-linux-gnu/default/gcc", "avr-freestanding-none/default/gcc" }, .items = &.{
        "1.0i", "2.5if", "1.0il", "1.0iw", "1.0iq", "1.0if16", "0.1if32", "0.1if64", "0.1if32x", "0.1if64x", "1e309i", "0x1p-1075i", "0.0i",
    } },
};

const pp_number_items = [_][]const u8{
    "0",                     "1",                    "0x10",                 "010",
    "0b101",                 "0o17",                 "1u",                   "1l",
    "1ull",                  "1wb",                  "1uwb",                 "2147483648",
    "4294967295",            "9223372036854775807",  "9223372036854775808",  "9223372036854775808u",
    "9223372036854775808ll", "18446744073709551615", "18446744073709551616", "18446744073709551616u",
    "0xFFFFFFFFFFFFFFFF",    "0x8000000000000000",   "0x10000000000000000",  "99999999999999999999",
    "99999999999999999999u", "1.0",                  "1e5",                  "0x1p0",
    "1i",                    "1.0i",                 "1f",                   "08",
    "1'000",                 "0i8",                  "1i64",                 "1ui64",
};

const char_items = [_][]const u8{
    // plain char: escapes
    "'a'",          "' '",           "'\\0'",           "'\\n'",           "'\\''",         "'\\\"'",         "'\"'",                   "'\\\\'",
    "'\\?'",        "'\\a'",         "'\\b'",           "'\\f'",           "'\\r'",         "'\\t'",          "'\\v'",                  "'\\e'",
    "'\\E'",        "'\\('",         "'\\['",           "'\\{'",           "'\\%'",         "'\\q'",          "'\\8'",                  "'\\9'",
    "'\\ '",        "'\\\t'",        "'\\x'",           "'\\xg'",          "'\\x41'",       "'\\x7f'",        "'\\x80'",                "'\\xff'",
    "'\\xFF'",      "'\\x100'",      "'\\x0000000041'", "'\\x0000000100'", "'\\xFFFFFFFF'", "'\\x100000000'", "'\\xFFFFFFFFF'",         "'\\1'",
    "'\\01'",       "'\\177'",       "'\\200'",         "'\\377'",         "'\\400'",       "'\\777'",        "'\\1234'",               "'\\0101'",
    "'\\08'",
    // multichar
          "'ab'",          "'abc'",           "'abcd'",          "'abcde'",       "'\\1\\2\\3\\4'", "'\\xff\\xff\\xff\\xff'", "'\\xff\\xff\\xff\\xff\\xff'",
    "'\\x00\\xFF'", "'\\x80\\x00'",  "'ABC\\D'",        "'abc\\E'",
    // UTF-8 text, invalid encodings
           "'\xc3\xa9'",    "'\xe2\x82\xac'", "'\xf0\x9f\x98\x80'",     "'a\xc3\xa9'",
    "'\xc3'",       "'\x80'",        "'\xff'",          "'\xff\xfe'",      "'a\xff'",       "'\xc3\xa9\xff'", "'\xed\xa0\x80'",
    // UCNs
            "'\\u0041'",
    "'\\u0024'",    "'\\u0040'",     "'\\u0060'",       "'\\u001F'",       "'\\u0000'",     "'\\u007F'",      "'\\u0080'",              "'\\u009F'",
    "'\\u00A0'",    "'\\u00e9'",     "'\\uD7FF'",       "'\\uD800'",       "'\\uDBFF'",     "'\\uDC00'",      "'\\uDFFF'",              "'\\uE000'",
    "'\\uFFFF'",    "'\\U00010000'", "'\\U0010FFFF'",   "'\\U00110000'",   "'\\UFFFFFFFF'", "'\\U0001F600'",  "'\\u12'",                "'\\u'",
    "'\\U'",        "'\\U1234'",     "'\\u12345'",      "'\\ug'",          "'\\U0000DFFF'",
    // backslash before a non-ASCII byte (Ascii.init @intCast)
    "'\\\xc3\xa9'",
    // empty / unterminated tokens
      "''",                     "'a",
    "'\\'",
};

/// Contents used with every char prefix (L, u, U, u8).
const char_prefix_bodies = [_][]const u8{
    "a",           "ab",           "abcd",             "\\0",          "\\x7F",       "\\x80",       "\\xFF",
    "\\x100",      "\\xFFFF",      "\\x10000",         "\\x7FFF",      "\\x8000",     "\\x7FFFFFFF", "\\x80000000",
    "\\xFFFFFFFF", "\\x100000000", "\\377",            "\\777",        "\\u0041",     "\\u0024",     "\\u00A0",
    "\\u00e9",     "\\u7FFF",      "\\u8000",          "\\uFFFF",      "\\U00010000", "\\U0010FFFF", "\\uD800",
    "\xc3\xa9",    "\xe2\x82\xac", "\xf0\x9f\x98\x80", "\xef\xbf\xbf", "\xc3",        "\xff",        "a\xff",
    "\\q",         "\\e",
};

const StringCase = []const []const u8;

const string_items = [_]StringCase{
    &.{"\"\""},                              &.{"\"abc\""},                     &.{"\"a\\0b\""},                               &.{"\"\\x41\\x42\""},
    &.{"\"\\xFF\""},                         &.{"\"\\x100\""},                  &.{"\"\\777\""},                               &.{"\"\\377\""},
    &.{"\"\\x\""},                           &.{"\"\\q\""},                     &.{"\"\\e[1m\""},                              &.{"\"\\u00e9\""},
    &.{"\"\xc3\xa9\""},                      &.{"\"\xf0\x9f\x98\x80\""},        &.{"\"\\U0001F600\""},                         &.{"\"\\uD800\""},
    &.{"\"\\U00110000\""},                   &.{"\"\\u0041\""},                 &.{"\"\\u0024\""},                             &.{"\"\\u0001\""},
    &.{"\"\xc3\""},                          &.{"\"a\xffb\""},                  &.{"\"\\xC3\""},                               &.{"\"\\u12\""},
    &.{"\"\\x41\\u00e9\\xFF\""},             &.{"\"abc\\x606262 \""},           &.{"\"\\\xc3\xa9\""},
    // wide and unicode kinds
                             &.{"L\"\""},
    &.{"L\"abc\""},                          &.{"L\"\xc3\xa9\""},               &.{"L\"\xf0\x9f\x98\x80\""},                   &.{"L\"\\U0001F600\""},
    &.{"L\"\\xFFFF\""},                      &.{"L\"\\x10000\""},               &.{"L\"\\x7FFFFFFF\""},                        &.{"L\"\\xFFFFFFFF\""},
    &.{"L\"\\x8000\""},                      &.{"L\"\\uFFFF\""},                &.{"L\"\xff\""},                               &.{"u\"abc\""},
    &.{"u\"\xc3\xa9\""},                     &.{"u\"\xf0\x9f\x98\x80\""},       &.{"u\"\\U0001F600\""},                        &.{"u\"\\xD800\""},
    &.{"u\"\\xFFFF\""},                      &.{"u\"\\x10000\""},               &.{"u\"\xff\""},                               &.{"U\"abc\""},
    &.{"U\"\xf0\x9f\x98\x80\""},             &.{"U\"\\U0010FFFF\""},            &.{"U\"\\xFFFFFFFF\""},                        &.{"U\"\\x100000000\""},
    &.{"u8\"abc\""},                         &.{"u8\"\xc3\xa9\""},              &.{"u8\"\\xFF\""},                             &.{"u8\"\\u00e9\""},
    &.{"u8\"\xff\""},
    // concatenation
                           &.{ "\"a\"", "\"b\"" },            &.{ "\"a\"", "L\"b\"" },                       &.{ "L\"a\"", "\"b\"" },
    &.{ "L\"a\"", "L\"b\"" },                &.{ "L\"a\"", "u\"b\"" },          &.{ "u\"a\"", "U\"b\"" },                      &.{ "u8\"a\"", "\"b\"" },
    &.{ "\"a\"", "u8\"b\"" },                &.{ "u8\"a\"", "u\"b\"" },         &.{ "U\"a\"", "U\"b\"" },                      &.{ "u8\"a\"", "u8\"b\"" },
    &.{ "\"a\"", "L\"b\"", "\"c\"" },        &.{ "\"a\"", "u\"b\"", "U\"c\"" }, &.{ "\"\xff\"", "\"x\"" },                     &.{ "\"x\"", "\"\xff\"" },
    &.{ "\"\\xff\"", "\"x\"" },              &.{ "L\"\"", "\"\xff\"" },         &.{ "\"\xc3\xa9\"", "L\"\xf0\x9f\x98\x80\"" }, &.{ "\"\\x12\"", "\"3\"" },
    &.{ "\"\\u00e9\"", "u\"\\U0001F600\"" }, &.{ "\"a\\q\"", "\"\\x\"" },
    // unterminated
          &.{"\"abc"},                                   &.{ "\"a\"", "\"b" },
    &.{ "L\"a\"", "u\"b\"", "\"c" },
};

const ucn_ident_items = [_][]const u8{
    "\\u0061",   "ABC\\U00000001", "\\UFFFFFFFF", "\\u4F60\\u597D", "a\\u4F60\\u597D", "\\U0001F525",
    "x\\u00e9y", "\\u0024",        "\\uD800",     "\\U00110000",    "\\u00A0",         "\\u0040",
};

// ===========================================================================
// Generators
// ===========================================================================

fn genSuffix(o: *Out) !void {
    o.comment("--- prefix: number_literal.Prefix.fromString(buf, allow_msvc) and number_literal.Prefix.stringLen(buf)", .{});
    const prefix_inputs = [_][]const u8{
        "0",   "1",  "00", "0x", "0x1",  "0X1", "0b",  "0b1", "0B1",  "0o",   "0o1", "0O1",
        "0'1", "0'", "01", "08", "0e1",  "0.5", "0E1", "0u",  "0l",   "0ul",  "0i",  "0i8",
        "0wb", "0z", ".5", "9",  "0x'1", "0b'", "0o'", "0lu", "0i64", "0ui8", "0q",  "0'1'2",
    };
    for (prefix_inputs) |buf| {
        for ([_]bool{ false, true }) |msvc| {
            const pre = number_literal.Prefix.fromString(buf, msvc);
            try o.w.print("prefix {d} ", .{@intFromBool(msvc)});
            try pct(o.w, buf, false);
            try o.w.print(" = {s} {d} {s}\n", .{ @tagName(pre), pre.stringLen(buf), prov });
            o.count += 1;
        }
    }
    o.comment("--- suffix: number_literal.Suffix.fromString(buf, kind, allow_msvc) (invalid = null)", .{});
    const suffix_inputs = [_][]const u8{
        "",     "u",   "U",     "l",     "L",    "ll",    "LL",    "lL",   "Ll",   "ul",    "lu",    "Ul",
        "uL",   "LU",  "ull",   "llu",   "LLU",  "uLL",   "ulL",   "lul",  "uu",   "lll",   "wb",    "WB",
        "Wb",   "wB",  "uwb",   "wbu",   "UWB",  "Uwb",   "i",     "I",    "j",    "iu",    "ui",    "il",
        "li",   "ill", "lli",   "iull",  "llui", "iwb",   "wbi",   "iuwb", "uiwb", "ii",    "i8",    "I8",
        "ui8",  "Ui8", "UI8",   "i16",   "ui16", "i32",   "ui32",  "i64",  "I64",  "ui64",  "UI64",  "i128",
        "u8",   "f",   "F",     "w",     "W",    "q",     "Q",     "f16",  "F16",  "bf16",  "BF16",  "Bf16",
        "bF16", "f32", "F32",   "f64",   "f128", "F128",  "f32x",  "F32x", "f32X", "F32X",  "f64x",  "f128x",
        "d32",  "D32", "d64",   "d128",  "D128", "d64x",  "D64X",  "dd",   "df",   "if",    "fi",    "iw",
        "wi",   "iq",  "qi",    "if16",  "f16i", "if128", "f128i", "if32", "if64", "if32x", "if64x", "id32",
        "fl",   "ff",  "ibf16", "bf16i", "x",    "e",
    };
    for (suffix_inputs) |buf| {
        for ([_][]const u8{ "int", "float" }) |kind_name| {
            for ([_]bool{ false, true }) |msvc| {
                const s = if (kind_name[0] == 'i')
                    number_literal.Suffix.fromString(buf, .int, msvc)
                else
                    number_literal.Suffix.fromString(buf, .float, msvc);
                try o.w.print("suffix {s} {d} ", .{ kind_name, @intFromBool(msvc) });
                if (buf.len == 0) try o.w.writeAll("-") else try pct(o.w, buf, false);
                try o.w.print(" = {s} {s}\n", .{ if (s) |t| @tagName(t) else "invalid", prov });
                o.count += 1;
            }
        }
    }
    o.comment("--- suffix_props: isImaginary isSignedInteger(- if unreachable) isBitInt isFloat80 isMSVCExtension", .{});
    inline for (comptime std.meta.fieldNames(number_literal.Suffix)) |f_name| {
        const s: number_literal.Suffix = @field(number_literal.Suffix, f_name);
        const float_only = switch (s) {
            .F, .IF, .F16, .F128, .IF128, .Q, .IQ, .W, .IW, .IF16, .F32, .IF32, .F64, .IF64, .F32x, .IF32x, .F64x, .IF64x, .D32, .D64, .D128, .D64x, .BF16 => true,
            else => false,
        };
        try o.w.print("suffix_props {s} = {d} {s} {d} {d} {d} {s}\n", .{
            f_name,
            @intFromBool(s.isImaginary()),
            if (float_only) "-" else if (s.isSignedInteger()) "1" else "0",
            @intFromBool(s.isBitInt()),
            @intFromBool(s.isFloat80()),
            @intFromBool(s.isMSVCExtension()),
            prov,
        });
        o.count += 1;
    }
}

fn genNumber(o: *Out) !void {
    for (number_groups) |g| {
        o.comment("--- {s}", .{g.title});
        for (g.cfgs) |cfg| {
            for (g.items) |lit| {
                try numberLine(o.w, cfg, lit);
                o.count += 1;
            }
        }
    }
}

fn genPp(o: *Out) !void {
    o.comment("--- pp_number: #if value of a pp-number (Preprocessor/Parser.zig primaryExpr)", .{});
    for ([_][]const u8{ cfg_main, "x86_64-linux-gnu/c23/gcc", "x86_64-linux-gnu/default/clang/ms", "avr-freestanding-none/default/gcc" }) |cfg| {
        for (pp_number_items) |lit| {
            try ppNumberLine(o.w, cfg, lit);
            o.count += 1;
        }
    }
    o.comment("--- pp_char: #if value of a character constant", .{});
    const pp_cfgs = [_][]const u8{ cfg_main, "aarch64-linux-gnu/default/gcc", "x86_64-windows-msvc/default/msvc/ms", "avr-freestanding-none/default/gcc", "x86_64-linux-gnu/default/gcc/uchar" };
    const pp_chars = [_][]const u8{
        "'a'",            "'\\xff'", "'\\x80'",    "'\\377'",        "'ab'",       "'\\xff\\xff'", "'abcd'",
        "'abcde'",        "L'a'",    "L'\\xff'",   "L'\\x7fff'",     "L'\\x8000'", "L'\\xffff'",   "L'\\xFFFFFFFF'",
        "L'\\x7FFFFFFF'", "u'a'",    "u'\\xffff'", "U'\\xFFFFFFFF'", "u8'a'",      "u8'\\xff'",    "'\xc3\xa9'",
        "'\xff'",         "L'ab'",
    };
    for (pp_cfgs) |cfg| {
        for (pp_chars) |tok| {
            if (try ppCharLine(o.w, cfg, tok)) o.count += 1;
        }
    }
}

fn genChar(o: *Out) !void {
    o.comment("--- plain character constants", .{});
    for (cfgs_text) |cfg| {
        for (char_items) |tok| {
            try charLine(o.w, cfg, tok);
            o.count += 1;
        }
        try charLine(o.w, cfg, "'a'");
        o.count += 1;
    }
    o.comment("--- prefixed character constants (L, u, U, u8)", .{});
    for (cfgs_text) |cfg| {
        for ([_][]const u8{ "L", "u", "U", "u8" }) |pre| {
            for (char_prefix_bodies) |body| {
                const tok = try std.fmt.allocPrint(gpa, "{s}'{s}'", .{ pre, body });
                try charLine(o.w, cfg, tok);
                o.count += 1;
            }
        }
    }
    o.comment("--- char signedness override", .{});
    for ([_][]const u8{ "x86_64-linux-gnu/default/gcc/uchar", "aarch64-linux-gnu/default/gcc/schar" }) |cfg| {
        for ([_][]const u8{ "'\\xff'", "'\\x80'", "'\\x7f'", "'\\377'", "'\xff'", "'\xc3\xa9'", "'\\xff\\xff'", "'\\u00A0'" }) |tok| {
            try charLine(o.w, cfg, tok);
            o.count += 1;
        }
    }
}

fn genString(o: *Out) !void {
    o.comment("--- string literals and concatenation (Parser.stringLiteral)", .{});
    for (cfgs_text) |cfg| {
        for (string_items) |toks| {
            try stringLine(o.w, cfg, toks);
            o.count += 1;
        }
    }
    o.comment("--- ucn_ident: Preprocessor.unescapeUcn decoding of an extended identifier", .{});
    for ([_][]const u8{ cfg_main, "x86_64-linux-gnu/c89/gcc", "x86_64-linux-gnu/c23/gcc" }) |cfg| {
        for (ucn_ident_items) |id| {
            try ucnIdentLine(o.w, cfg, id);
            o.count += 1;
        }
    }
}

fn genKinds(o: *Out) !void {
    o.comment("--- kind_info: maxCodepoint maxInt charLiteralType elementType charUnitSize internalStorageAlignment wcharMax", .{});
    for (cfgs_all) |cfg| {
        const comp = try makeComp(cfg);
        for ([_]text_literal.Kind{ .char, .wide, .utf_8, .utf_16, .utf_32 }) |k| {
            try o.w.print("kind_info {s} {s} = 0x{x} 0x{x} {f} {f} {d} {d} 0x{x} {s}\n", .{
                cfg,                               @tagName(k),
                k.maxCodepoint(comp),              k.maxInt(comp),
                k.charLiteralType(comp),           k.elementType(comp),
                @backingInt(k.charUnitSize(comp)), k.internalStorageAlignment(comp),
                comp.wcharMax(),                   prov,
            });
            o.count += 1;
        }
    }
    o.comment("--- concat: text_literal.Kind.concat(a, b)", .{});
    const all = [_]text_literal.Kind{ .char, .wide, .utf_8, .utf_16, .utf_32, .unterminated };
    for (all) |a| for (all) |b| {
        const r = a.concat(b) catch null;
        try o.w.print("concat {s} {s} = {s} {s}\n", .{ @tagName(a), @tagName(b), if (r) |k| @tagName(k) else "cannot_concat", prov });
        o.count += 1;
    };
    o.comment("--- target_info: char signedness, wchar_t, intmax_t, uint_least16_t, uint_least32_t, int/long/long long/double/long double bits, has_int128, float80", .{});
    for (cfgs_all) |cfg| {
        const comp = try makeComp(cfg);
        try o.w.print("target_info {s} = {s} {f} {f} {f} {f} {d} {d} {d} {d} {d} {d} {s} {s}\n", .{
            cfg,
            if (comp.getCharSignedness() == .signed) "schar" else "uchar",
            comp.type_store.wchar,
            comp.type_store.intmax,
            comp.type_store.uint_least16_t,
            comp.type_store.uint_least32_t,
            Int.int.bits(comp),
            Int.long.bits(comp),
            Int.long_long.bits(comp),
            Float.double.bits(comp),
            Float.long_double.bits(comp),
            @intFromBool(targetHasInt128(&comp.target)),
            if (comp.float80Type()) |_| "long_double" else "none",
            prov,
        });
        o.count += 1;
    }
}

// ===========================================================================
// Cross-check of fixtures.txt
// ===========================================================================

const Check = struct {
    agree: usize = 0,
    disagree: usize = 0,
    skipped: usize = 0,
};

fn unpct(s: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '%' and i + 2 < s.len) {
            out.append(gpa, std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16) catch @panic("bad pct")) catch @panic("oom");
            i += 2;
        } else out.append(gpa, s[i]) catch @panic("oom");
    }
    return out.items;
}

fn fmtAlloc(comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(gpa, fmt, args) catch @panic("oom");
}

fn parseHexInt(s: []const u8) i256 {
    const neg = s[0] == '-';
    const digits = if (neg) s[3..] else s[2..];
    const v = std.fmt.parseInt(i256, digits, 16) catch @panic("bad int");
    return if (neg) -v else v;
}

/// Evaluate one fixture line; returns null if it agrees, else a description.
fn checkFixture(line: []const u8) !?[]const u8 {
    const bar = mem.find(u8, line, " | ");
    const head = if (bar) |b| line[0..b] else line;
    var fields: std.ArrayList([]const u8) = .empty;
    var it = mem.tokenizeScalar(u8, head, ' ');
    while (it.next()) |f| try fields.append(gpa, f);
    const f = fields.items;
    const eq = for (f, 0..) |x, i| {
        if (mem.eql(u8, x, "=")) break i;
    } else unreachable;
    const op_name = f[0];
    if (mem.eql(u8, op_name, "fixture_diag")) {
        // fixture_diag case line:col cfg op inputs... = tok:off kind prov | message
        const cfg = f[3];
        const op = f[4];
        const inputs = f[5..eq];
        const tok_off = f[eq + 1];
        var msg = unpct(line[bar.? + 3 ..]);
        if (mem.findLast(u8, msg, " [-W")) |i| msg = msg[0..i];
        const comp = try makeComp(cfg);
        reset(comp);
        var p: P = .{ .comp = comp };
        if (mem.eql(u8, op, "number")) {
            _ = p.parseNumberToken(unpct(inputs[0])) catch {};
        } else if (mem.eql(u8, op, "pp_number")) {
            _ = try ppNum(&p, unpct(inputs[0]));
        } else if (mem.eql(u8, op, "char")) {
            const tok = unpct(inputs[0]);
            _ = try p.charLiteral(TokId.of(tok), tok);
        } else if (mem.eql(u8, op, "pp_char")) {
            const tok = unpct(inputs[0]);
            _ = try ppChar(&p, TokId.of(tok), tok);
        } else if (mem.eql(u8, op, "string")) {
            const n = try std.fmt.parseInt(usize, inputs[0], 10);
            const toks = try gpa.alloc([]const u8, n);
            const ids = try gpa.alloc(TokId, n);
            for (toks, ids, 0..) |*t, *id, i| {
                t.* = unpct(inputs[1 + i]);
                id.* = TokId.of(t.*);
            }
            _ = try p.stringLiteral(ids, toks);
        } else if (mem.eql(u8, op, "ucn_ident")) {
            _ = try unescapeUcn(comp, unpct(inputs[0]));
        } else return error.UnknownOp;
        for (comp.diags.items) |d| {
            if (mem.eql(u8, d.text, msg) and mem.eql(u8, fmtAlloc("{d}:{d}", .{ d.tok, d.offset }), tok_off)) return null;
        }
        var aw: std.Io.Writer.Allocating = .init(gpa);
        try aw.writer.writeAll("probe diagnostics:");
        for (comp.diags.items) |d| try aw.writer.print(" [{d}:{d} {s}]", .{ d.tok, d.offset, d.text });
        return aw.written();
    }
    if (mem.eql(u8, op_name, "fixture_type") or mem.eql(u8, op_name, "fixture_eq")) {
        // fixture_x case line cfg op lit = expected prov
        const cfg = f[3];
        const op = f[4];
        const lit = unpct(f[5]);
        const want = f[eq + 1];
        const comp = try makeComp(cfg);
        reset(comp);
        var p: P = .{ .comp = comp };
        var qt: QualType = undefined;
        var val: i256 = 0;
        if (mem.eql(u8, op, "number")) {
            const r = p.parseNumberToken(lit) catch return "probe: parse failed";
            qt = r.qt;
            if (r.val == .int) val = r.val.int.toInt(i256) catch 0;
        } else {
            const r = try p.charLiteral(TokId.of(lit), lit);
            qt = r.qt;
            val = switch (r.parsed) {
                .signed => |s| s,
                .unsigned => |u| u,
            };
        }
        if (op_name[8] == 't') {
            const got = fmtAlloc("{f}", .{qt});
            if (mem.eql(u8, got, want)) return null;
            return fmtAlloc("probe type {s}", .{got});
        }
        const w = parseHexInt(want);
        if (val == w) return null;
        // equality after the usual arithmetic conversions to an unsigned type
        if (qt.tag == .int and !qt.complex and qt.signedness(comp) == .unsigned) {
            const bits: u9 = @intCast(qt.bitSizeof(comp));
            const m: i256 = @as(i256, 1) << @intCast(bits);
            if (@mod(w, m) == @mod(val, m)) return null;
        }
        return fmtAlloc("probe value {d} ({f})", .{ val, qt });
    }
    if (mem.eql(u8, op_name, "fixture_ast")) {
        // fixture_ast case cfg op inputs... = type value prov
        const cfg = f[2];
        const op = f[3];
        const want_ty = unpct(f[eq + 1]);
        const want_val = unpct(f[eq + 2]);
        const comp = try makeComp(cfg);
        reset(comp);
        var p: P = .{ .comp = comp };
        if (mem.eql(u8, op, "string")) {
            const tok = unpct(f[5]);
            const r = try p.stringLiteral(&.{TokId.of(tok)}, &.{tok});
            const got_ty = fmtAlloc("[{d}]char", .{r.ok.qt.len});
            const got_val = fmtAlloc("\"{s}\"", .{r.ok.bytes[0 .. r.ok.bytes.len - 1]});
            if (mem.eql(u8, got_ty, want_ty) and mem.eql(u8, got_val, want_val)) return null;
            return fmtAlloc("probe {s} {s}", .{ got_ty, got_val });
        }
        const lit = unpct(f[4]);
        const r = p.parseNumberToken(lit) catch return "probe: parse failed";
        const got_ty = fmtAlloc("{f}", .{r.qt});
        var aw: std.Io.Writer.Allocating = .init(gpa);
        switch (r.val) {
            .int => |c| try aw.writer.print("{d}", .{c.toInt(i256) catch 0}),
            .float => |x| try x.printAst(&aw.writer),
            .complex => |c| {
                try c[0].printAst(&aw.writer);
                try aw.writer.writeAll(" + ");
                try c[1].printAst(&aw.writer);
                try aw.writer.writeAll("i");
            },
            .none => try aw.writer.writeAll("none"),
        }
        const got_val = aw.written();
        if (mem.eql(u8, got_ty, want_ty) and mem.eql(u8, got_val, want_val)) return null;
        return fmtAlloc("probe {s} {s}", .{ got_ty, got_val });
    }
    return error.UnknownFixtureOp;
}

fn crossCheck(io: std.Io, dir: std.Io.Dir) !Check {
    const data = try dir.readFileAlloc(io, "fixtures.txt", gpa, .unlimited);
    var check: Check = .{};
    var it = mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        if (try checkFixture(line)) |why| {
            check.disagree += 1;
            std.debug.print("fixture disagreement: {s}\n    {s}\n", .{ line, why });
        } else check.agree += 1;
    }
    return check;
}

// ===========================================================================

const Gen = struct {
    file: []const u8,
    ops: []const u8,
    title: []const u8,
    f: *const fn (*Out) anyerror!void,
};

pub fn main(init: std.process.Init) !void {
    arena_state = .init(std.heap.page_allocator);
    gpa = arena_state.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(gpa);
    if (args.len != 2) {
        std.debug.print("usage: literal_probe <out-dir>\n", .{});
        return error.Usage;
    }
    var dir = try std.Io.Dir.cwd().openDir(io, args[1], .{});
    defer dir.close(io);

    const gens = [_]Gen{
        .{ .file = "suffix.txt", .ops = "prefix, suffix, suffix_props", .title = "number_literal.zig number_literal.Prefix / number_literal.Suffix tables", .f = genSuffix },
        .{ .file = "number.txt", .ops = "number", .title = "Parser.parseNumberToken: number_literal.Parser.parse + parseInt/fixedSizeInt/bitInt/parseFloat", .f = genNumber },
        .{ .file = "pp.txt", .ops = "pp_number, pp_char", .title = "Preprocessor/Parser.zig primaryExpr for pp-numbers and character constants", .f = genPp },
        .{ .file = "char.txt", .ops = "char", .title = "Parser.charLiteral: text_literal.Parser.parse of character constants", .f = genChar },
        .{ .file = "string.txt", .ops = "string, ucn_ident", .title = "Parser.stringLiteral (decoding + concatenation) and Preprocessor.unescapeUcn", .f = genString },
        .{ .file = "kinds.txt", .ops = "kind_info, concat, target_info", .title = "text_literal.Kind per target and the target facts the literal code reads", .f = genKinds },
    };
    for (gens) |g| {
        var aw: std.Io.Writer.Allocating = .init(gpa);
        var o: Out = .{ .w = &aw.writer };
        o.comment("{s}", .{g.title});
        o.comment("Generated by test/migration/literal_probe.zig (dev-only); do not edit by hand.", .{});
        o.comment("Format, encoding and provenance tags: see README.md in this directory.", .{});
        o.comment("Ops in this file: {s}", .{g.ops});
        o.comment("Reference run: Zig 0.17.0 port of the Aro 0.18-dev sources (not the pinned Zig build).", .{});
        try g.f(&o);
        try aw.writer.print("# end: {d} vectors\n", .{o.count});
        try dir.writeFile(io, .{ .sub_path = g.file, .data = aw.written() });
        std.debug.print("{s}: {d} vectors\n", .{ g.file, o.count });
    }

    const check = try crossCheck(io, dir);
    std.debug.print("fixtures.txt cross-check: {d} agree, {d} disagree\n", .{ check.agree, check.disagree });
}
