// Owner: 12.3 type-desc (contract frozen by plan 12 stage 0).
// Port of src/aro/Builtins/TypeDescription.zig (component/type iterators over
// a builtin `param_str`) and of Builtins.zig createType / createBuiltin /
// specForSize, which build C3 types directly through TypeStore (no fake
// Parser and no TypeStore.Builder, which is not ported).
//
// Invariants:
// - Iterators never allocate; a TypeDescription is a self-contained value
//   (fixed arrays, not slices into the iterator), so it stays valid after
//   `next()` is called again.
// - Malformed param strings (Zig `unreachable`) yield MALFORMED instead of
//   crashing; every param_str in the generated tables must iterate to END
//   without MALFORMED (checked by //test/c3:builtins_tests).
// - create_type / create_builtin only allocate through comp.type_store; out of
//   memory panics. Unsupported specs (q, Q, E) return type_store::INVALID as in
//   Zig.
module aro::builtin_type_description;
import aro, aro::compilation, aro::type_store, aro::builtin_properties;

<* Iteration finished (Zig `null`). *>
excuse END;
<* The param string is not valid type-description syntax (Zig `unreachable`). *>
excuse MALFORMED;

<* TypeDescription.Prefix. *>
enum Prefix : char
{
	L,   // long (Li = long int, Ld = long double)
	LL,  // long long (LLi; LLd = __float128)
	LLL, // __int128_t (LLLi)
	Z,   // int32_t (requires a native 32-bit integer type)
	W,   // int64_t (requires a native 64-bit integer type)
	N,   // 'int' if the target is LP64, 'L' otherwise
	O,   // long for OpenCL targets, long long otherwise
	S,   // signed
	U,   // unsigned
	I,   // required to constant fold to an integer constant expression
}

<* TypeDescription.Spec tag. code: the param_str spelling. *>
enum SpecTag : char (String code)
{
	VOID            { "v" },
	BOOL            { "b" },
	CHAR            { "c" },
	SHORT           { "s" },
	INT             { "i" },
	HALF            { "h" },  // __fp16 (OpenCL half)
	FLOAT16         { "x" },  // _Float16
	BF16            { "y" },  // __bf16
	MFP8            { "m" },  // __mfp8
	FLOAT           { "f" },
	DOUBLE          { "d" },
	SIZE            { "z" },  // size_t
	WCHAR           { "w" },  // wchar_t
	CF_STRING       { "F" },  // constant CFString
	VA_LIST         { "a" },  // __builtin_va_list
	VA_LIST_REF     { "A" },  // "reference" to __builtin_va_list
	VECTOR          { "V" },  // count = element count, followed by the element type
	SCALABLE_VECTOR { "q" },  // count = element count
	TARGET_TYPE     { "Q" },  // target_type selects the type
	EXT_VECTOR      { "E" },  // count = element count
	COMPLEX         { "X" },  // complex_base selects the base type
	PTRDIFF         { "Y" },  // ptrdiff_t
	FILE            { "P" },  // FILE
	JMP_BUF         { "J" },  // jmp_buf
	SIGJMP_BUF      { "SJ" }, // sigjmp_buf
	UCONTEXT        { "K" },  // ucontext_t
	PID             { "p" },  // pid_t
}

<* Spec.Q payload. code: the character after 'Q'. *>
enum TargetType : char (char code)
{
	AARCH64_SVCOUNT_T          { 'a' },
	AMDGPU_BUFFER_RSRC_T       { 'b' },
	AMDGPU_FEATURE_PREDICATE_T { 'c' },
	AMDGPU_TEXTURE_T           { 't' },
}

<* Spec.X payload. *>
enum ComplexBase : char
{
	FLOAT,       // Xf
	DOUBLE,      // Xd
	LONG_DOUBLE, // XLd
}

<* TypeDescription.Spec. Only the payload matching `tag` is meaningful. *>
struct Spec
{
	SpecTag tag;
	uint count;              // VECTOR, SCALABLE_VECTOR, EXT_VECTOR
	TargetType target_type;  // TARGET_TYPE
	ComplexBase complex_base; // COMPLEX
}

<* TypeDescription.Suffix tag. *>
enum SuffixTag : char
{
	POINTER,  // '*', optionally followed by one address-space digit
	CONST,    // 'C'
	VOLATILE, // 'D'
	RESTRICT, // 'R'
}

struct Suffix
{
	SuffixTag tag;
	<* POINTER only: Zig `?u8` address space. *>
	bool has_addr_space;
	char addr_space;
}

enum ComponentKind : char { PREFIX, SPEC, SUFFIX }

<* TypeDescription.Component. Only the field matching `kind` is meaningful. *>
struct Component
{
	ComponentKind kind;
	Prefix prefix;
	Spec spec;
	Suffix suffix;
}

const usz MAX_PREFIXES = 4;
const usz MAX_SUFFIXES = 4;

<* One type of a builtin signature: prefixes, a spec, suffixes. *>
struct TypeDescription
{
	Prefix[MAX_PREFIXES] prefix_buf;
	char prefix_len;
	Spec spec;
	Suffix[MAX_SUFFIXES] suffix_buf;
	char suffix_len;
}

fn Prefix[] TypeDescription.prefixes(&self) => self.prefix_buf[:self.prefix_len];
fn Suffix[] TypeDescription.suffixes(&self) => self.suffix_buf[:self.suffix_len];

<*
 TypeDescription.ComponentIterator over `str` (no NUL terminator needed: the
 end of the slice plays the role of Zig's sentinel).
*>
struct ComponentIterator
{
	String str;
	usz idx;
}

fn ComponentIterator component_iterator(String str) => { .str = str, .idx = 0 };

<* Next component; END at the end or after the trailing varargs '.'. *>
fn Component? ComponentIterator.next(&self)
{
	char c = self.at(self.idx);
	if (c == 0) return END~;
	self.idx++;
	switch (c)
	{
		case 'L':
			if (self.at(self.idx) != 'L') return prefix_component(L);
			self.idx++;
			if (self.at(self.idx) != 'L') return prefix_component(LL);
			self.idx++;
			return prefix_component(LLL);
		case 'Z': return prefix_component(Z);
		case 'W': return prefix_component(W);
		case 'N': return prefix_component(N);
		case 'O': return prefix_component(O);
		case 'S':
			if (self.at(self.idx) == 'J')
			{
				self.idx++;
				return spec_component({ .tag = SIGJMP_BUF });
			}
			return prefix_component(S);
		case 'U': return prefix_component(U);
		case 'I': return prefix_component(I);

		case 'v': return spec_component({ .tag = VOID });
		case 'b': return spec_component({ .tag = BOOL });
		case 'c': return spec_component({ .tag = CHAR });
		case 's': return spec_component({ .tag = SHORT });
		case 'i': return spec_component({ .tag = INT });
		case 'h': return spec_component({ .tag = HALF });
		case 'x': return spec_component({ .tag = FLOAT16 });
		case 'y': return spec_component({ .tag = BF16 });
		case 'm': return spec_component({ .tag = MFP8 });
		case 'f': return spec_component({ .tag = FLOAT });
		case 'd': return spec_component({ .tag = DOUBLE });
		case 'z': return spec_component({ .tag = SIZE });
		case 'w': return spec_component({ .tag = WCHAR });
		case 'F': return spec_component({ .tag = CF_STRING });
		case 'a': return spec_component({ .tag = VA_LIST });
		case 'A': return spec_component({ .tag = VA_LIST_REF });
		case 'V':
		case 'q':
		case 'E':
			// Zig: std.fmt.parseUnsigned(u32, digits) catch unreachable.
			usz start = self.idx;
			ulong count = 0;
			while (char_is_digit(self.at(self.idx)))
			{
				count = count * 10 + (ulong)(self.at(self.idx) - '0');
				if (count > 0xFFFF_FFFF) return MALFORMED~;
				self.idx++;
			}
			if (self.idx == start) return MALFORMED~;
			SpecTag tag = c == 'V' ? VECTOR : c == 'q' ? SCALABLE_VECTOR : EXT_VECTOR;
			return spec_component({ .tag = tag, .count = (uint)count });
		case 'X':
			char next = self.at(self.idx);
			self.idx++; // Zig: defer self.idx += 1
			switch (next)
			{
				case 'f': return spec_component({ .tag = COMPLEX, .complex_base = FLOAT });
				case 'd': return spec_component({ .tag = COMPLEX, .complex_base = DOUBLE });
				case 'L':
					self.idx++;
					return spec_component({ .tag = COMPLEX, .complex_base = LONG_DOUBLE });
				default: return MALFORMED~;
			}
		case 'Y': return spec_component({ .tag = PTRDIFF });
		case 'P': return spec_component({ .tag = FILE });
		case 'J': return spec_component({ .tag = JMP_BUF });
		case 'K': return spec_component({ .tag = UCONTEXT });
		case 'p': return spec_component({ .tag = PID });
		case '.':
			// Can only appear at the end of the param string; marks a varargs function.
			if (self.at(self.idx) != 0) return MALFORMED~;
			return END~;
		case '*':
			char next = self.at(self.idx);
			if (char_is_digit(next))
			{
				self.idx++;
				return suffix_component({ .tag = POINTER, .has_addr_space = true, .addr_space = next - '0' });
			}
			return suffix_component({ .tag = POINTER });
		case 'C': return suffix_component({ .tag = CONST });
		case 'D': return suffix_component({ .tag = VOLATILE });
		case 'R': return suffix_component({ .tag = RESTRICT });
		case 'Q':
			char next = self.at(self.idx);
			self.idx++; // Zig: defer self.idx += 1
			foreach (tt : TargetType::values)
			{
				if (tt.code == next) return spec_component({ .tag = TARGET_TYPE, .target_type = tt });
			}
			return MALFORMED~;
		default:
			return MALFORMED~;
	}
}

<* The byte at `i`, or 0 past the end (Zig's sentinel). *>
fn char ComponentIterator.at(&self, usz i) @inline => i < self.str.len ? self.str[i] : 0;

fn bool char_is_digit(char c) @local @inline => c >= '0' && c <= '9';
fn Component prefix_component(Prefix p) @local @inline => { .kind = PREFIX, .prefix = p };
fn Component spec_component(Spec s) @local @inline => { .kind = SPEC, .spec = s };
fn Component suffix_component(Suffix s) @local @inline => { .kind = SUFFIX, .suffix = s };

<* Like next() but does not advance. *>
fn Component? ComponentIterator.peek(&self)
{
	usz idx = self.idx;
	defer self.idx = idx;
	return self.next();
}

<*
 TypeDescription.TypeIterator: yields the return type first, then each
 parameter. A trailing '.' (varargs) is not a type; see
 builtin_properties::is_var_args.
*>
struct TypeIterator
{
	String param_str;
	usz idx;
}

fn TypeIterator type_iterator(String param_str) => { .param_str = param_str, .idx = 0 };

<*
 Next type description; END when the string is exhausted (or only the
 trailing varargs '.' is left). MALFORMED on bad syntax, on a suffix before
 any spec, on more than MAX_PREFIXES / MAX_SUFFIXES, and on prefixes with no
 spec after them (Zig silently returns null there; no .def entry does it).
*>
fn TypeDescription? TypeIterator.next(&self)
{
	ComponentIterator it = component_iterator(self.param_str[self.idx..]);
	defer self.idx += it.idx;

	TypeDescription desc;
	bool has_spec = false;
	while LOOP: (true)
	{
		Component? component = it.peek();
		if (catch f = component)
		{
			if (f == END) break;
			return f~;
		}
		switch (component.kind)
		{
			case PREFIX:
				if (has_spec) break LOOP;
				if (desc.prefix_len == MAX_PREFIXES) return MALFORMED~;
				desc.prefix_buf[desc.prefix_len++] = component.prefix;
			case SPEC:
				if (has_spec) break LOOP;
				has_spec = true;
				desc.spec = component.spec;
			case SUFFIX:
				if (!has_spec) return MALFORMED~;
				if (desc.suffix_len == MAX_SUFFIXES) return MALFORMED~;
				desc.suffix_buf[desc.suffix_len++] = component.suffix;
		}
		(void)it.next();
	}
	if (!has_spec)
	{
		if (desc.prefix_len) return MALFORMED~;
		return END~;
	}
	return desc;
}

// ---------------------------------------------------------------------------
// Type building (Builtins.createType / createBuiltin / specForSize)
// ---------------------------------------------------------------------------

<*
 The subset of TypeStore.Builder.Specifier that builtin descriptions can
 reach. Combinations Zig would report through the (undefined) Parser
 (cannotCombine / duplicateSpec) make the result INVALID instead.
*>
enum BuilderSpec : char @local
{
	NONE,
	VOID,
	BOOL,
	CHAR,
	SCHAR,
	UCHAR,
	UNSIGNED,
	SIGNED,
	SHORT,
	SSHORT,
	USHORT,
	SHORT_INT,
	SSHORT_INT,
	USHORT_INT,
	INT,
	SINT,
	UINT,
	LONG,
	SLONG,
	ULONG,
	LONG_INT,
	SLONG_INT,
	ULONG_INT,
	LONG_LONG,
	SLONG_LONG,
	ULONG_LONG,
	LONG_LONG_INT,
	SLONG_LONG_INT,
	ULONG_LONG_INT,
	INT128,
	SINT128,
	UINT128,
	BF16,
	FP16,
	MFP8,
	FLOAT16,
	FLOAT,
	DOUBLE,
	LONG_DOUBLE,
	FLOAT128,
	COMPLEX,
	COMPLEX_LONG,
	COMPLEX_FLOAT,
	COMPLEX_DOUBLE,
	COMPLEX_LONG_DOUBLE,
	OTHER, // Builder `.other = qt`
}

<* The parts of TypeStore.Builder that createType uses. *>
struct TypeBuilder @local
{
	BuilderSpec type;
	QualType other;
	bool is_const;
	bool is_volatile;
	bool is_restrict;
	<* A combination Zig reports through the undefined Parser (or asserts against) was seen. *>
	bool bad;
}

<* Builder.combine for the reachable specifiers. *>
fn void TypeBuilder.combine(&b, BuilderSpec new)
{
	if (b.type == OTHER && b.other.is_invalid()) return;
	BuilderSpec cur = b.type;
	BuilderSpec res = NONE;
	switch (new)
	{
		case SIGNED:
			switch (cur)
			{
				case NONE: res = SIGNED;
				case CHAR: res = SCHAR;
				case SHORT: res = SSHORT;
				case SHORT_INT: res = SSHORT_INT;
				case INT: res = SINT;
				case LONG: res = SLONG;
				case LONG_INT: res = SLONG_INT;
				case LONG_LONG: res = SLONG_LONG;
				case LONG_LONG_INT: res = SLONG_LONG_INT;
				case INT128: res = SINT128;
				default: break;
			}
		case UNSIGNED:
			switch (cur)
			{
				case NONE: res = UNSIGNED;
				case CHAR: res = UCHAR;
				case SHORT: res = USHORT;
				case SHORT_INT: res = USHORT_INT;
				case INT: res = UINT;
				case LONG: res = ULONG;
				case LONG_INT: res = ULONG_INT;
				case LONG_LONG: res = ULONG_LONG;
				case LONG_LONG_INT: res = ULONG_LONG_INT;
				case INT128: res = UINT128;
				default: break;
			}
		case CHAR:
			switch (cur)
			{
				case NONE: res = CHAR;
				case UNSIGNED: res = UCHAR;
				case SIGNED: res = SCHAR;
				default: break;
			}
		case SHORT:
			switch (cur)
			{
				case NONE: res = SHORT;
				case UNSIGNED: res = USHORT;
				case SIGNED: res = SSHORT;
				case INT: res = SHORT_INT;
				case SINT: res = SSHORT_INT;
				case UINT: res = USHORT_INT;
				default: break;
			}
		case INT:
			switch (cur)
			{
				case NONE: res = INT;
				case SIGNED: res = SINT;
				case UNSIGNED: res = UINT;
				case SHORT: res = SHORT_INT;
				case SSHORT: res = SSHORT_INT;
				case USHORT: res = USHORT_INT;
				case LONG: res = LONG_INT;
				case SLONG: res = SLONG_INT;
				case ULONG: res = ULONG_INT;
				case LONG_LONG: res = LONG_LONG_INT;
				case SLONG_LONG: res = SLONG_LONG_INT;
				case ULONG_LONG: res = ULONG_LONG_INT;
				default: break;
			}
		case LONG:
			switch (cur)
			{
				case NONE: res = LONG;
				case DOUBLE: res = LONG_DOUBLE;
				case UNSIGNED: res = ULONG;
				case SIGNED: res = SLONG;
				case INT: res = LONG_INT;
				case UINT: res = ULONG_INT;
				case SINT: res = SLONG_INT;
				case LONG: res = LONG_LONG;
				case SLONG: res = SLONG_LONG;
				case ULONG: res = ULONG_LONG;
				case LONG_INT: res = LONG_LONG_INT;
				case ULONG_INT: res = ULONG_LONG_INT;
				case SLONG_INT: res = SLONG_LONG_INT;
				case COMPLEX: res = COMPLEX_LONG;
				case COMPLEX_DOUBLE: res = COMPLEX_LONG_DOUBLE;
				default: break;
			}
		case LONG_LONG:
			switch (cur)
			{
				case NONE: res = LONG_LONG;
				case UNSIGNED: res = ULONG_LONG;
				case SIGNED: res = SLONG_LONG;
				case INT: res = LONG_LONG_INT;
				case SINT: res = SLONG_LONG_INT;
				case LONG: res = LONG_LONG;
				case SLONG: res = SLONG_LONG;
				case ULONG: res = ULONG_LONG;
				case COMPLEX: res = COMPLEX_LONG; // sic: Zig maps complex + long long to complex_long
				default: break;
			}
		case INT128:
			switch (cur)
			{
				case NONE: res = INT128;
				case UNSIGNED: res = UINT128;
				case SIGNED: res = SINT128;
				default: break;
			}
		case FLOAT:
			switch (cur)
			{
				case NONE: res = FLOAT;
				case COMPLEX: res = COMPLEX_FLOAT;
				default: break;
			}
		case DOUBLE:
			switch (cur)
			{
				case NONE: res = DOUBLE;
				case LONG: res = LONG_DOUBLE;
				case COMPLEX_LONG: res = COMPLEX_LONG_DOUBLE;
				case COMPLEX: res = COMPLEX_DOUBLE;
				default: break;
			}
		case COMPLEX:
			switch (cur)
			{
				case NONE: res = COMPLEX;
				case FLOAT: res = COMPLEX_FLOAT;
				case DOUBLE: res = COMPLEX_DOUBLE;
				case LONG_DOUBLE: res = COMPLEX_LONG_DOUBLE;
				case LONG: res = COMPLEX_LONG;
				default: break;
			}
		default:
			// void, bool, __fp16, __bf16, __mfp8, _Float16.
			if (cur == NONE) res = new;
	}
	if (res == NONE)
	{
		// Zig: cannotCombine / duplicateSpec through the undefined Parser.
		b.bad = true;
		return;
	}
	b.type = res;
}

<* Builder.fromType: basic types lose typedefs and qualifiers, others are kept as `.other`. *>
fn void TypeBuilder.set_from_type(&b, Compilation* comp, QualType qt)
{
	if (b.type != NONE) b.bad = true; // Zig: assert(builder.type == .none)
	b.type = OTHER;
	if (qt.is_invalid())
	{
		b.other = qt;
		return;
	}
	BaseType base = qt.base(comp);
	switch (base.ty.tag)
	{
		case VOID:
		case BOOL:
		case INT:
		case FLOAT:
		case STORAGE_FLOAT:
		case COMPLEX:
		case BIT_INT:
			b.other = base.qt.unqualified();
		default:
			b.other = qt;
	}
}

<* Builder.finish + finishQuals. *>
fn QualType TypeBuilder.finish(&b, Compilation* comp)
{
	if (b.bad) return type_store::INVALID;
	QualType qt;
	switch (b.type)
	{
		case NONE: return type_store::INVALID; // Zig: missing_type_specifier through the undefined Parser
		case VOID: qt = type_store::VOID;
		case BOOL: qt = type_store::BOOL;
		case CHAR: qt = type_store::CHAR;
		case SCHAR: qt = type_store::SCHAR;
		case UCHAR: qt = type_store::UCHAR;
		case UNSIGNED: qt = type_store::UINT;
		case SIGNED: qt = type_store::INT;
		case SHORT:
		case SSHORT:
		case SHORT_INT:
		case SSHORT_INT: qt = type_store::SHORT;
		case USHORT:
		case USHORT_INT: qt = type_store::USHORT;
		case INT:
		case SINT: qt = type_store::INT;
		case UINT: qt = type_store::UINT;
		case LONG:
		case SLONG:
		case LONG_INT:
		case SLONG_INT: qt = type_store::LONG;
		case ULONG:
		case ULONG_INT: qt = type_store::ULONG;
		case LONG_LONG:
		case SLONG_LONG:
		case LONG_LONG_INT:
		case SLONG_LONG_INT: qt = type_store::LONG_LONG;
		case ULONG_LONG:
		case ULONG_LONG_INT: qt = type_store::ULONG_LONG;
		case INT128:
		case SINT128: qt = type_store::INT128;
		case UINT128: qt = type_store::UINT128;
		case BF16: qt = type_store::BF16;
		case FP16: qt = type_store::FP16;
		case MFP8: qt = type_store::MFP8;
		case FLOAT16: qt = type_store::FLOAT16;
		case FLOAT: qt = type_store::FLOAT;
		case DOUBLE: qt = type_store::DOUBLE;
		case LONG_DOUBLE: qt = type_store::LONG_DOUBLE;
		case FLOAT128: qt = type_store::FLOAT128;
		case COMPLEX: qt = type_store::DOUBLE.to_complex(comp); // Zig also warns plain_complex
		case COMPLEX_LONG: qt = type_store::LONG.to_complex(comp); // Zig also warns complex_int
		case COMPLEX_FLOAT: qt = type_store::FLOAT.to_complex(comp);
		case COMPLEX_DOUBLE: qt = type_store::DOUBLE.to_complex(comp);
		case COMPLEX_LONG_DOUBLE: qt = type_store::LONG_DOUBLE.to_complex(comp);
		case OTHER: qt = b.other;
	}
	if (qt.is_invalid()) return type_store::INVALID;
	if (b.is_const) qt.is_const = true;
	if (b.is_volatile) qt.is_volatile = true;
	if (b.is_restrict)
	{
		switch (qt.base(comp).ty.tag)
		{
			case ARRAY:
			case POINTER: qt.is_restrict = true;
			default: break; // Zig: restrict_non_pointer through the undefined Parser; dropped here
		}
	}
	return qt;
}

<* Builtins.specForSize: the first of short/int/long/long long with `size_bits` bits; NONE if none (Zig unreachable). *>
fn BuilderSpec spec_for_size(Compilation* comp, ulong size_bits) @local
{
	if (type_store::SHORT.bit_sizeof(comp) == size_bits) return SHORT;
	if (type_store::INT.bit_sizeof(comp) == size_bits) return INT;
	if (type_store::LONG.bit_sizeof(comp) == size_bits) return LONG;
	if (type_store::LONG_LONG.bit_sizeof(comp) == size_bits) return LONG_LONG;
	return NONE;
}

<*
 Builtins.createType: builds the QualType for `desc`. For a VECTOR spec the
 element type is read from `it` (the element's suffixes apply to the vector).

 Target-dependent specs read the named types in comp.type_store (size_t,
 wchar_t, ptrdiff_t, pid_t, __builtin_va_list, NSConstantString), so
 type_store::init_named_types must have run. FILE / jmp_buf / sigjmp_buf /
 ucontext_t are INVALID until the parser records their typedefs, and the
 result is then INVALID, suffixes included (as in Zig). Scalable vectors (q),
 target types (Q) and ext vectors (E) are INVALID too; as in Zig their
 element type is not consumed and becomes the next parameter.

 Zig asserts, or reports through an undefined Parser, where a description is
 inconsistent (`N` on a non-int spec, specifiers that cannot combine, a
 suffix on `a`/`A`/`Y`/`J`/`SJ`/`p`/`V`, a nested vector); those yield
 INVALID here. `__int128` on a target without it (Zig: an error through the
 undefined Parser) still yields __int128, and `R` on a non-pointer is dropped.
*>
fn QualType create_type(Compilation* comp, TypeDescription desc, TypeIterator* it)
{
	TypeBuilder b = { .other = type_store::INVALID };
	Suffix[] actual_suffix = desc.suffixes();
	TypeDescription child_desc; // owns a vector element's suffixes

	bool require_native_int32 = false;
	bool require_native_int64 = false;
	foreach (prefix : desc.prefixes())
	{
		switch (prefix)
		{
			case L: b.combine(LONG);
			case LL: b.combine(LONG_LONG);
			case LLL: b.combine(INT128);
			case Z: require_native_int32 = true;
			case W: require_native_int64 = true;
			case N:
				if (desc.spec.tag != INT) return type_store::INVALID;
				if (!comp.target.is_lp64()) b.combine(LONG);
			case O:
				b.combine(LONG);
				if (comp.target.os.tag != OPENCL) b.combine(LONG);
			case S: b.combine(SIGNED);
			case U: b.combine(UNSIGNED);
			case I: break; // TODO in Zig: compile-time constant integer
		}
	}
	TypeStore* ts = &comp.type_store;
	switch (desc.spec.tag)
	{
		case VOID: b.combine(VOID);
		case BOOL: b.combine(BOOL);
		case CHAR: b.combine(CHAR);
		case SHORT: b.combine(SHORT);
		case INT:
			if (require_native_int32 || require_native_int64)
			{
				BuilderSpec s = spec_for_size(comp, require_native_int32 ? 32 : 64);
				if (s == NONE) return type_store::INVALID;
				b.combine(s);
			}
			else
			{
				switch (b.type)
				{
					case INT128:
					case SINT128:
					case UINT128: break;
					default: b.combine(INT);
				}
			}
		case HALF: b.combine(FP16);
		case FLOAT16: b.combine(FLOAT16);
		case BF16: b.combine(BF16);
		case MFP8: b.combine(MFP8);
		case FLOAT: b.combine(FLOAT);
		case DOUBLE:
			if (b.type == LONG_LONG)
			{
				b.type = FLOAT128;
			}
			else
			{
				b.combine(DOUBLE);
			}
		case SIZE: b.set_from_type(comp, ts.size);
		case WCHAR: b.set_from_type(comp, ts.wchar);
		case CF_STRING: b.set_from_type(comp, ts.ns_constant_string);
		case VA_LIST:
			if (desc.suffix_len) return type_store::INVALID;
			b.set_from_type(comp, ts.va_list);
		case VA_LIST_REF:
			if (desc.suffix_len) return type_store::INVALID;
			// Zig asserts va_list is not an array, because the Parser decays it
			// at startup. Decaying here gives that type before the Parser runs.
			QualType va_list = ts.va_list;
			if (!va_list.is_invalid() && va_list.is(comp, ARRAY)) va_list = va_list.decay(comp);
			b.set_from_type(comp, va_list);
		case VECTOR:
			if (desc.suffix_len) return type_store::INVALID;
			if (it == null) return type_store::INVALID; // nested vector: Zig passes `undefined`
			TypeDescription? next = it.next();
			if (catch next) return type_store::INVALID;
			child_desc = next;
			actual_suffix = child_desc.suffixes();
			TypeDescription elem_desc = child_desc;
			elem_desc.suffix_len = 0;
			QualType elem_qt = create_type(comp, elem_desc, null);
			b.type = OTHER;
			b.other = ts.put(type_store::type_vector(elem_qt, desc.spec.count));
		case SCALABLE_VECTOR: return type_store::INVALID; // TODO in Zig: scalable vector
		case TARGET_TYPE: return type_store::INVALID; // TODO in Zig: target builtin type
		case EXT_VECTOR: return type_store::INVALID; // TODO in Zig: ext_vector (OpenCL vector)
		case COMPLEX:
			b.combine(COMPLEX);
			switch (desc.spec.complex_base)
			{
				case FLOAT: b.combine(FLOAT);
				case DOUBLE: b.combine(DOUBLE);
				case LONG_DOUBLE:
					b.combine(LONG);
					b.combine(DOUBLE);
			}
		case PTRDIFF:
			if (desc.suffix_len) return type_store::INVALID;
			b.set_from_type(comp, ts.ptrdiff);
		case FILE:
			if (ts.file.is_invalid()) return ts.file;
			b.set_from_type(comp, ts.file);
		case JMP_BUF:
			if (desc.suffix_len) return type_store::INVALID;
			if (ts.jmp_buf.is_invalid()) return ts.jmp_buf;
			b.set_from_type(comp, ts.jmp_buf);
		case SIGJMP_BUF:
			if (desc.suffix_len) return type_store::INVALID;
			if (ts.sigjmp_buf.is_invalid()) return ts.sigjmp_buf;
			b.set_from_type(comp, ts.sigjmp_buf);
		case UCONTEXT:
			if (ts.ucontext_t.is_invalid()) return ts.ucontext_t;
			b.set_from_type(comp, ts.ucontext_t);
		case PID:
			if (desc.suffix_len) return type_store::INVALID;
			b.set_from_type(comp, ts.pid_t);
	}
	foreach (suffix : actual_suffix)
	{
		switch (suffix.tag)
		{
			case POINTER:
				// TODO in Zig: the address space is not represented.
				QualType child = b.finish(comp);
				if (b.bad) return type_store::INVALID;
				b.is_const = false;
				b.is_volatile = false;
				b.is_restrict = false;
				b.type = OTHER;
				b.other = ts.put(type_store::type_pointer(child));
			case CONST: b.is_const = true;
			case VOLATILE: b.is_volatile = true;
			case RESTRICT: b.is_restrict = true;
		}
	}
	return b.finish(comp);
}

<*
 Builtins.createBuiltin: the function type for a whole param_str (variadic if
 is_var_args). A malformed param_str, or one with more than 32 parameters
 (Zig's fixed buffer), gives INVALID.
*>
fn QualType create_builtin(Compilation* comp, String param_str)
{
	TypeIterator it = type_iterator(param_str);
	TypeDescription? ret_desc = it.next();
	if (catch ret_desc) return type_store::INVALID;
	QualType ret_ty = create_type(comp, ret_desc, &it);

	FuncParam[32] params;
	usz param_count = 0;
	while (true)
	{
		TypeDescription? desc = it.next();
		if (catch f = desc)
		{
			if (f == END) break;
			return type_store::INVALID;
		}
		if (param_count == params.len) return type_store::INVALID;
		params[param_count++] = type_store::func_param(create_type(comp, desc, &it));
	}
	FuncKind kind = builtin_properties::is_var_args(param_str) ? VARIADIC : NORMAL;
	return comp.type_store.put(type_store::type_func(ret_ty, kind, params[:param_count]));
}
