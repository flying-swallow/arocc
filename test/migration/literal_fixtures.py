#!/usr/bin/env python3
"""Extract literal-decoding expectations from test/cases into vectors.

Development-only generator for test/c3/data/literals/fixtures.txt (plan 11,
agent 11.5). Nothing in Bazel runs it. Usage, from the repo root:

    python3 test/migration/literal_fixtures.py [--out test/c3/data/literals/fixtures.txt]

It reads every top-level test/cases/*.c fixture and its manifest and emits
four kinds of vectors (line format: test/c3/data/literals/README.md):

  fixture_diag  an expected diagnostic whose text matches one of the literal
                diagnostic templates (number_literal.zig, text_literal.zig and
                the literal diagnostics of Parser.zig / Preprocessor), with the
                literal token(s) found at the reported line:column.
  fixture_type  VALUE_HAS_TYPE(lit, T) / EXPECT_TYPE(lit, T) on a single
                literal token (include/test_helpers.h).
  fixture_eq    _Static_assert(lit == N, ...) where lit is a single literal
                token and N a plain integer or simple character constant.
  fixture_ast   int/float/imaginary/string literal nodes of
                test/cases/ast/<case>.c paired with their source token.

All values are copied from the fixtures (the oracle). The literal spelling,
the configuration and, for fixture_ast, the token pairing are recovered
heuristically; test/migration/literal_probe.zig re-evaluates every vector
and reports disagreements (README "Cross-check").
"""

import argparse
import os
import re
import sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
CASES = os.path.join(ROOT, "test", "cases")

# ---------------------------------------------------------------------------
# Literal diagnostic templates: (template id, fmt). Ids are the Zig names.

TEMPLATES = [
    # Tokenizer/number_literal.zig
    ("invalid_binary_digit", "invalid digit '{c}' in binary constant"),
    ("invalid_octal_digit", "invalid digit '{c}' in octal constant"),
    ("invalid_int_suffix", "invalid suffix '{s}' on integer constant"),
    ("invalid_float_suffix", "invalid suffix '{s}' on floating constant"),
    ("hex_floating_constant_requires_exponent", "hexadecimal floating constant requires an exponent"),
    ("exponent_has_no_digits", "exponent has no digits"),
    ("c23_binary", "binary integer literals are a C23 extension"),
    ("pre_c23_binary", "octal integer literals are incompatible with C standards before C23"),
    ("bitint_suffix", "'_BitInt' suffix for literals is a C23 extension"),
    ("pre_c23_bitint", "'_BitInt' suffix for literals is incompatible with C standards before C23"),
    ("c2y_octal", "octal integer literals are a C2y extension"),
    ("pre_c2y_octal", "octal integer literals are incompatible with C standards before C2y"),
    ("c2y_deprecated_octal", "octal literals without a '0o' prefix are deprecated"),
    # Tokenizer/text_literal.zig
    ("illegal_char_encoding", "illegal character encoding in character literal"),
    ("missing_hex_escape", "\\{c} used with no following hex digits"),
    ("escape_sequence_overflow", "escape sequence out of range"),
    ("incomplete_universal_character", "incomplete universal character name"),
    ("invalid_universal_character", "invalid universal character"),
    ("char_too_large", "character too large for enclosing character literal type"),
    ("ucn_basic_char_error", "character '{c}' cannot be specified by a universal character name"),
    ("ucn_basic_char_warning", "specifying character '{c}' with a universal character name is incompatible with C standards before C23"),
    ("ucn_control_char_error", "universal character name refers to a control character"),
    ("ucn_control_char_warning", "universal character name referring to a control character is incompatible with C standards before C23"),
    ("c89_ucn_in_literal", "universal character names are only valid in C99 or later"),
    ("non_standard_escape_char", "use of non-standard escape character '\\{c}'"),
    ("unknown_escape_sequence", "unknown escape sequence '\\{c}'"),
    ("multichar_literal", "multi-character character constant"),
    ("invalid_multichar_literal", "{s} character literals may not contain multiple characters"),
    ("char_lit_too_wide", "character constant too long for its type"),
    ("u8_char_lit", "UTF-8 character literal is a C23 extension"),
    # Parser.zig / Preprocessor literal diagnostics
    ("int_literal_too_big", "integer literal is too large to be represented in any integer type"),
    ("implicitly_unsigned_literal", "integer literal is too large to be represented in a signed integer type, interpreting as unsigned"),
    ("gnu_imaginary_constant", "imaginary constants are a GNU extension"),
    ("float_literal_in_expr", "floating point literal in preprocessor expression"),
    ("unsupported_str_cat", "unsupported string literal concatenation"),
    ("empty_char_literal_error", "empty character constant"),
    ("unterminated_char_literal_error", "missing terminating ' character"),
]


def template_regex(fmt):
    out = ""
    i = 0
    while i < len(fmt):
        if fmt.startswith("{s}", i):
            out += ".*"
            i += 3
        elif fmt.startswith("{c}", i):
            out += "(?:.|x[0-9a-f]{2})"
            i += 3
        else:
            out += re.escape(fmt[i])
            i += 1
    return re.compile("^" + out + "$")


TEMPLATE_RES = [(tid, template_regex(fmt)) for tid, fmt in TEMPLATES]
OPTION_SUFFIX = re.compile(r" \[-W[^\]]*\]$")

# ---------------------------------------------------------------------------
# Field encoding (README "Encoding")


def pct(data, allow_space=False):
    if isinstance(data, str):
        data = data.encode("utf-8", "surrogateescape")
    out = []
    for b in data:
        if (0x21 <= b <= 0x7E or (allow_space and b == 0x20)) and b not in (0x25, 0x7C):
            out.append(chr(b))
        else:
            out.append("%%%02X" % b)
    return "".join(out)


# ---------------------------------------------------------------------------
# Manifest and configuration


STD_NAMES = {
    "c89": "c89", "c90": "c89", "iso9899:1990": "c89", "iso9899:199409": "iso9899",
    "gnu89": "gnu89", "gnu90": "gnu89", "c99": "c99", "iso9899:1999": "c99", "c9x": "c99",
    "iso9899:199x": "c99", "gnu99": "gnu99", "gnu9x": "gnu99", "c11": "c11",
    "iso9899:2011": "c11", "c1x": "c11", "iso9899:201x": "c11", "gnu11": "gnu11",
    "c17": "c17", "iso9899:2017": "c17", "c18": "c17", "iso9899:2018": "c17",
    "gnu17": "gnu17", "gnu18": "gnu17", "c23": "c23", "iso9899:2024": "c23",
    "gnu23": "gnu23", "c2x": "c23", "gnu2x": "gnu23", "c2y": "c2y", "gnu2y": "gnu23",
}

NATIVE = "x86_64-linux-gnu"


def system_compiler(triple):
    """Target.systemCompiler for the triples the fixtures use."""
    parts = triple.split("-")
    arch = parts[0]
    os_ = parts[1] if len(parts) > 1 else ""
    abi = parts[2] if len(parts) > 2 else ""
    if os_.startswith(("macos", "ios", "tvos", "watchos", "visionos", "driverkit", "maccatalyst")) or \
            abi.startswith("android") or os_.startswith(("freebsd", "netbsd", "openbsd", "dragonfly")) or \
            os_ in ("fuchsia", "illumos", "haiku") or arch == "hexagon":
        return "clang"
    if os_ == "uefi":
        return "msvc"
    if abi.startswith("gnu") or os_.startswith("linux"):
        return "gcc"
    if os_.startswith("windows"):
        return "msvc"
    if arch == "avr":
        return "gcc"
    return "clang"


def parse_manifest(contents):
    start = contents.find("/** manifest:")
    end = contents.rfind("*/")
    if start < 0 or end < 0:
        return None
    lines = contents[start + len("/** manifest:"):end].strip(" \t\r\n").split("\n")
    kind = lines[0].strip()
    args = []
    i = 1
    while i < len(lines):
        t = lines[i].strip(" \t\r")
        i += 1
        if not t:
            break
        key, _, value = t.partition("=")
        if key.strip() == "args":
            args = value.split()
    trailing = [l.strip(" \t\r") for l in lines[i:]]
    return kind, args, trailing


def config_of(args):
    triple = None
    std = "default"
    emulate = None
    ms = None
    char = None
    for a in args:
        if a.startswith("--target="):
            triple = a[len("--target="):]
        elif a.startswith("-target="):
            triple = a[len("-target="):]
        elif a.startswith("-std="):
            std = STD_NAMES.get(a[5:], a[5:])
        elif a.startswith("--emulate="):
            emulate = a[len("--emulate="):]
        elif a == "-fms-extensions":
            ms = True
        elif a == "-fno-ms-extensions":
            ms = False
        elif a == "-funsigned-char":
            char = "uchar"
        elif a == "-fsigned-char":
            char = "schar"
    if emulate is None and triple is not None:
        emulate = system_compiler(triple)
    if emulate is None:
        emulate = "no"
    ms_ext = (emulate == "msvc") if ms is None else ms
    cfg = "%s/%s/%s" % (triple or NATIVE, std, emulate)
    if ms_ext:
        cfg += "/ms"
    if char:
        cfg += "/" + char
    return cfg


# ---------------------------------------------------------------------------
# A small lexer: literal tokens with line / byte column, comments skipped.

PREFIXES = ("u8", "u", "U", "L")
# A UCN inside an identifier (the tokenizer's extended_identifier rule, simplified).
UCN_AT = re.compile(rb"\\(?:u[0-9A-Fa-f]{4}|U[0-9A-Fa-f]{8})")
IDENT_START = re.compile(r"[A-Za-z_\x80-\xff]")


class Tok:
    def __init__(self, kind, text, line, col_byte, pp_directive):
        self.kind = kind          # 'number' | 'char' | 'string' | 'ident' | 'punct'
        self.text = text          # bytes
        self.line = line          # 1-based
        self.col_byte = col_byte  # 0-based byte offset in the line
        self.pp = pp_directive    # directive name of the line, '' if none

    @property
    def end(self):
        return self.col_byte + len(self.text)


def lex(src):
    """Return all tokens of `src` (bytes). Splices are not handled (the few
    fixtures with spliced literals are skipped by the callers)."""
    toks = []
    i = 0
    n = len(src)
    line = 1
    line_start = 0
    at_line_start = True
    directive = ""
    pending_directive = False
    while i < n:
        c = src[i:i + 1]
        if c == b"\n":
            i += 1
            line += 1
            line_start = i
            at_line_start = True
            if not (i >= 2 and src[i - 2:i - 1] == b"\\"):
                directive = ""
            continue
        if c in b" \t\r\f\v":
            i += 1
            continue
        if src.startswith(b"//", i):
            j = src.find(b"\n", i)
            i = n if j < 0 else j
            continue
        if src.startswith(b"/*", i):
            j = src.find(b"*/", i + 2)
            j = n if j < 0 else j + 2
            line += src.count(b"\n", i, j)
            k = src.rfind(b"\n", i, j)
            if k >= 0:
                line_start = k + 1
            i = j
            continue
        col = i - line_start
        if at_line_start and c == b"#":
            pending_directive = True
            at_line_start = False
            toks.append(Tok("punct", b"#", line, col, ""))
            i += 1
            continue
        at_line_start = False
        # prefixed literal?
        m = None
        for p in PREFIXES:
            pb = p.encode()
            if src.startswith(pb, i) and i + len(pb) < n and src[i + len(pb):i + len(pb) + 1] in (b"'", b'"'):
                m = pb
                break
        if m is not None or c in (b"'", b'"'):
            pre = m or b""
            q = src[i + len(pre):i + len(pre) + 1]
            j = i + len(pre) + 1
            while j < n and src[j:j + 1] != q and src[j:j + 1] != b"\n":
                if src[j:j + 1] == b"\\" and j + 1 < n:
                    j += 2
                else:
                    j += 1
            if j < n and src[j:j + 1] == q:
                j += 1
            text = src[i:j]
            toks.append(Tok("char" if q == b"'" else "string", text, line, col, directive))
            i = j
            continue
        if c.isdigit() or (c == b"." and i + 1 < n and src[i + 1:i + 2].isdigit()):
            j = i + 1
            while j < n:
                d = src[j:j + 1]
                if d in b"eEpP" and j + 1 < n and src[j + 1:j + 2] in b"+-":
                    j += 2
                elif d.isalnum() or d in b"._'" or (d and d[0] >= 0x80):
                    j += 1
                else:
                    break
            toks.append(Tok("number", src[i:j], line, col, directive))
            i = j
            continue
        if IDENT_START.match(c.decode("latin-1")) or UCN_AT.match(src, i):
            j = i
            while j < n:
                um = UCN_AT.match(src, j)
                if um:
                    j = um.end()
                elif src[j:j + 1].isalnum() or src[j:j + 1] == b"_" or src[j] >= 0x80:
                    j += 1
                else:
                    break
            text = src[i:j]
            if pending_directive:
                directive = text.decode("latin-1")
                pending_directive = False
            toks.append(Tok("ident", text, line, col, directive))
            i = j
            continue
        pending_directive = False
        toks.append(Tok("punct", c, line, col, directive))
        i += 1
    return toks


def line_byte_of_col(line_bytes, col):
    """Byte offset in the line for Aro's 1-based column (Source.lineCol counts
    one column per valid UTF-8 sequence, one per invalid byte)."""
    i = 0
    c = 1
    while c < col and i < len(line_bytes):
        b = line_bytes[i]
        ln = 1 if b < 0x80 else 2 if b >> 5 == 6 else 3 if b >> 4 == 14 else 4 if b >> 3 == 30 else 0
        if ln == 0 or i + ln > len(line_bytes):
            i += 1
        else:
            try:
                line_bytes[i:i + ln].decode("utf-8")
                i += ln
            except UnicodeDecodeError:
                i += 1
        c += 1
    return i


def string_run(toks, idx):
    """The adjacent string-literal tokens around toks[idx] (same directive context)."""
    lo = idx
    while lo > 0 and toks[lo - 1].kind == "string" and toks[lo - 1].pp == toks[idx].pp:
        lo -= 1
    hi = idx
    while hi + 1 < len(toks) and toks[hi + 1].kind == "string" and toks[hi + 1].pp == toks[idx].pp:
        hi += 1
    return lo, hi


def op_input(toks, idx):
    """(op, input fields, token index within the input) for the literal token at idx."""
    t = toks[idx]
    in_if = t.pp in ("if", "elif")
    if t.kind == "ident":
        return "ucn_ident", [pct(t.text)], 0
    if t.kind == "number":
        return ("pp_number" if in_if else "number"), [pct(t.text)], 0
    if t.kind == "char":
        return ("pp_char" if in_if else "char"), [pct(t.text)], 0
    lo, hi = string_run(toks, idx)
    return "string", [str(hi - lo + 1)] + [pct(x.text) for x in toks[lo:hi + 1]], idx - lo


# ---------------------------------------------------------------------------
# Python-side literal evaluation (only used to pair AST nodes with tokens)

INT_RE = re.compile(r"^(0[xX][0-9A-Fa-f']+|0[bB][01']+|0[oO]?[0-7']*|[1-9][0-9']*)([uUlLiIjJwWbB]*)$")


def int_value(text):
    m = INT_RE.match(text)
    if not m:
        return None
    d = m.group(1).replace("'", "")
    if d[:2] in ("0x", "0X"):
        return int(d[2:], 16)
    if d[:2] in ("0b", "0B"):
        return int(d[2:], 2)
    if d[:2] in ("0o", "0O"):
        return int(d[2:], 8)
    if d.startswith("0") and len(d) > 1:
        return int(d[1:], 8)
    return int(d)


FLOAT_RE = re.compile(r"^(0[xX][0-9A-Fa-f'.]*[pP][+-]?[0-9']+|[0-9'.]*[0-9.][0-9'.]*(?:[eE][+-]?[0-9']+)?)([a-zA-Z0-9]*)$")


def float_value(text):
    m = FLOAT_RE.match(text)
    if not m:
        return None
    body = m.group(1).replace("'", "")
    try:
        if body[:2] in ("0x", "0X"):
            return float.fromhex(body)
        return float(body)
    except ValueError:
        return None


C_TYPES = {
    "char": "char", "signed char": "schar", "unsigned char": "uchar",
    "short": "short", "short int": "short", "unsigned short": "ushort", "unsigned short int": "ushort",
    "int": "int", "signed": "int", "signed int": "int", "unsigned": "uint", "unsigned int": "uint",
    "long": "long", "long int": "long", "unsigned long": "ulong", "unsigned long int": "ulong",
    "long long": "long_long", "long long int": "long_long",
    "unsigned long long": "ulong_long", "unsigned long long int": "ulong_long",
    "__int128": "int128", "unsigned __int128": "uint128",
    "float": "float", "double": "double", "long double": "long_double",
    "_Float16": "float16", "__bf16": "bf16", "__float128": "float128", "_Float128": "float128",
    "_Float32": "float32", "_Float64": "float64", "_Float32x": "float32x", "_Float64x": "float64x",
    "_Decimal32": "dfloat32", "_Decimal64": "dfloat64", "_Decimal128": "dfloat128", "_Decimal64x": "dfloat64x",
}


def norm_type(t):
    t = " ".join(t.split())
    if t.startswith("_Complex "):
        inner = C_TYPES.get(t[len("_Complex "):])
        return None if inner is None else "complex_" + inner
    m = re.match(r"^(unsigned )?_BitInt\((\d+)\)$", t)
    if m:
        return ("bitint_u" if m.group(1) else "bitint_s") + m.group(2)
    return C_TYPES.get(t)


# ---------------------------------------------------------------------------
# Extraction


DIAG_LINE = re.compile(r"^(.*?):(\d+):(\d+): (error|warning|note|fatal error): (.*)$")


def extract_diags(name, src, toks, cfg, trailing, out):
    lines = src.split(b"\n")
    by_line = {}
    for k, t in enumerate(toks):
        by_line.setdefault(t.line, []).append(k)
    for d in trailing:
        m = DIAG_LINE.match(d)
        if not m or m.group(1) != name + ".c":
            continue
        line, col, kind, msg = int(m.group(2)), int(m.group(3)), m.group(4), m.group(5)
        if msg.endswith("[-Winvalid-pp-token]"):
            continue  # tokenizer / preprocessor token diagnostics, not literal decoding
        bare = OPTION_SUFFIX.sub("", msg)
        tid = next((t for t, r in TEMPLATE_RES if r.match(bare)), None)
        if tid is None:
            continue
        loc = "%d:%d" % (line, col)
        found = None
        if 1 <= line <= len(lines):
            b = line_byte_of_col(lines[line - 1], col)
            for k in by_line.get(line, []):
                t = toks[k]
                if (t.kind in ("number", "char", "string") or (t.kind == "ident" and b"\\" in t.text)) and t.col_byte <= b < max(t.end, t.col_byte + 1):
                    found = (k, b - t.col_byte)
                    break
        if found is None:
            print("unlocated: %s.c:%s %s" % (name, loc, msg), file=sys.stderr)
            continue
        k, off = found
        op, inputs, tok_i = op_input(toks, k)
        out.append("fixture_diag %s %s %s %s %s = %d:%d %s fixture | %s" % (
            pct(name), loc, cfg, op, " ".join(inputs), tok_i, off, kind.replace(" ", "_"), pct(msg, True)))


TYPE_MACRO = re.compile(r"(!?)\s*\b(VALUE_HAS_TYPE|EXPECT_TYPE)\s*\(\s*([^,()]+?)\s*,\s*([^()]+?)\s*\)")
EQ_ASSERT = re.compile(r"_Static_assert\s*\(\s*(\S+)\s*==\s*(-?\s*[0-9][0-9A-Fa-fxXuUlL]*|'[^'\\]')\s*[,)]")


def single_literal(text):
    toks = lex(text.encode("utf-8", "surrogateescape"))
    if len(toks) != 1 or toks[0].kind not in ("number", "char"):
        return None
    return toks[0]


def simple_int(text):
    text = text.replace(" ", "")
    neg = text.startswith("-")
    if neg:
        text = text[1:]
    if text.startswith("'"):
        v = ord(text[1])
    else:
        v = int_value(text)
        if v is None:
            return None
    return -v if neg else v


def extract_asserts(name, src, cfg, diag_lines, out):
    for ln, raw in enumerate(src.split(b"\n"), 1):
        line = raw.decode("utf-8", "surrogateescape")
        if ln in diag_lines or line.lstrip().startswith("#") or line.lstrip().startswith("//"):
            continue
        for m in TYPE_MACRO.finditer(line):
            if m.group(1):
                continue
            lit = single_literal(m.group(3))
            ty = norm_type(m.group(4))
            if lit is None or ty is None:
                continue
            op = "number" if lit.kind == "number" else "char"
            out.append("fixture_type %s %d %s %s %s = %s fixture" % (pct(name), ln, cfg, op, pct(lit.text), ty))
        for m in EQ_ASSERT.finditer(line):
            lit = single_literal(m.group(1))
            v = simple_int(m.group(2))
            if lit is None or v is None:
                continue
            op = "number" if lit.kind == "number" else "char"
            out.append("fixture_eq %s %d %s %s %s = %s fixture" % (pct(name), ln, cfg, op, pct(lit.text), fmt_int(v)))


def fmt_int(v):
    return ("-0x%x" % -v) if v < 0 else ("0x%x" % v)


AST_NODE = re.compile(r"^\s*(int_literal|float_literal|imaginary_literal|string_literal_expr|char_literal): '([^']*)'(?: lvalue)?(?: \(value: (.*)\))?$")


FLOAT_SUFFIX_TYPES = {
    "": "double", "f": "float", "l": "long_double", "f16": "float16", "bf16": "bf16",
    "q": "float128", "f128": "float128", "f32": "float32", "f64": "float64",
    "f32x": "float32x", "f64x": "float64x", "d32": "dfloat32", "d64": "dfloat64",
    "d128": "dfloat128", "d64x": "dfloat64x", "w": "long_double",
}


def suffix_consistent(text, node, nty):
    """Coarse pairing filter: the token's suffix must not contradict the node type."""
    if node == "float_literal":
        m = FLOAT_RE.match(text)
        if not m:
            return False
        want = FLOAT_SUFFIX_TYPES.get(m.group(2).lower())
        return want == nty
    if node == "int_literal":
        m = INT_RE.match(text)
        if not m or nty is None:
            return False
        suffix = m.group(2).lower()
        if "l" not in suffix and "w" not in suffix and int_value(text) < (1 << 15):
            # small values without l / wb suffix are int or unsigned int on every target
            return nty == ("uint" if "u" in suffix else "int")
        if "u" in suffix:
            return nty.startswith("u")
        if m.group(1)[0] in "123456789":  # decimal without u: always signed
            return not nty.startswith("u")
        return True
    return True


def extract_ast(name, src, toks, cfg, out):
    path = os.path.join(CASES, "ast", name + ".c")
    if not os.path.exists(path):
        return 0, 0
    with open(path, "rb") as f:
        nodes = []
        skip_child = False
        for raw in f.read().decode("utf-8", "surrogateescape").split("\n"):
            m = AST_NODE.match(raw)
            if not m:
                continue
            if skip_child:
                skip_child = False
                if m.group(1) == "float_literal" or m.group(1) == "int_literal":
                    continue
            nodes.append((m.group(1), m.group(2), m.group(3)))
            if m.group(1) == "imaginary_literal":
                skip_child = True
    lits = [t for t in toks if t.kind in ("number", "char", "string") and t.pp == ""]
    pos = 0
    paired = 0
    for node, ty, val in nodes:
        nty = norm_type(ty) if node != "string_literal_expr" else None
        if val is None:
            continue
        match = None
        for j in range(pos, min(len(lits), pos + 12)):
            t = lits[j]
            text = t.text.decode("utf-8", "surrogateescape")
            if node == "int_literal" and t.kind == "number":
                v = int_value(text)
                if v is not None and str(v) == val:
                    match = j
            elif node == "float_literal" and t.kind == "number":
                v = float_value(text)
                try:
                    want = float(val)
                except ValueError:
                    want = None
                if v is not None and want is not None and (v == want or abs(v - want) <= 1e-6 * max(1.0, abs(want))):
                    match = j
            elif node == "imaginary_literal" and t.kind == "number" and re.search(r"[iIjJ]", text):
                mm = re.match(r"^0 \+ (.*)i$", val)
                v = float_value(re.sub(r"[iIjJ]", "", text)) if mm else None
                if v is not None and float(mm.group(1)) == v:
                    match = j
            elif node == "string_literal_expr" and t.kind == "string" and text.startswith('"'):
                if val == text and "\\" not in text:
                    match = j
            if match is not None and not suffix_consistent(text, node, nty):
                match = None
            if match is not None:
                break
        if match is None:
            continue
        t = lits[match]
        pos = match + 1
        if node == "string_literal_expr":
            out.append("fixture_ast %s %s string 1 %s = %s %s fixture-ast" % (
                pct(name), cfg, pct(t.text), pct(ty), pct(val)))
        else:
            if nty is None:
                continue
            out.append("fixture_ast %s %s number %s = %s %s fixture-ast" % (
                pct(name), cfg, pct(t.text), nty, pct(val)))
        paired += 1
    return len(nodes), paired


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.join(ROOT, "test", "c3", "data", "literals", "fixtures.txt"))
    args = ap.parse_args()

    out = []
    stats = {"cases": 0, "diag": 0, "type": 0, "eq": 0, "ast": 0, "ast_nodes": 0}
    for fn in sorted(os.listdir(CASES)):
        if not fn.endswith(".c"):
            continue
        path = os.path.join(CASES, fn)
        with open(path, "rb") as f:
            src = f.read()
        man = parse_manifest(src.decode("utf-8", "surrogateescape"))
        if man is None:
            continue
        kind, margs, trailing = man
        name = fn[:-2]
        cfg = config_of(margs)
        # Strip the manifest so its text is not lexed as source.
        mstart = src.find(b"/** manifest:")
        mend = src.rfind(b"*/")
        body = src
        if 0 <= mstart < mend:
            region = src[mstart:mend + 2]
            body = src[:mstart] + bytes(b if b == 0x0A else 0x20 for b in region) + src[mend + 2:]
        toks = lex(body)
        before = len(out)
        if kind in ("syntax", "expand_error", "expand", "expand_partial"):
            extract_diags(name, body, toks, cfg, trailing, out)
        diag_lines = set()
        for d in trailing:
            m = DIAG_LINE.match(d)
            if m and m.group(1) == name + ".c":
                diag_lines.add(int(m.group(2)))
        extract_asserts(name, body, cfg, diag_lines, out)
        nodes, paired = extract_ast(name, body, toks, cfg, out)
        stats["ast_nodes"] += nodes
        if len(out) > before:
            stats["cases"] += 1
    for l in out:
        stats[l.split(" ", 1)[0].split("_", 1)[1]] += 1

    header = [
        "# Literal expectations extracted from test/cases fixtures (the oracle).",
        "# Generated by test/migration/literal_fixtures.py (dev-only); do not edit by hand.",
        "# Format, encoding and provenance tags: see README.md in this directory.",
        "# Ops in this file: fixture_diag, fixture_type, fixture_eq, fixture_ast",
        "# Cases contributing: %d; AST literal nodes seen: %d, paired: %d." % (stats["cases"], stats["ast_nodes"], stats["ast"]),
    ]
    with open(args.out, "w", newline="\n") as f:
        f.write("\n".join(header) + "\n")
        for l in out:
            f.write(l + "\n")
        f.write("# end: %d vectors\n" % len(out))
    print("fixtures.txt: %d vectors (diag %d, type %d, eq %d, ast %d of %d nodes) from %d cases" % (
        len(out), stats["diag"], stats["type"], stats["eq"], stats["ast"], stats["ast_nodes"], stats["cases"]), file=sys.stderr)


if __name__ == "__main__":
    main()
