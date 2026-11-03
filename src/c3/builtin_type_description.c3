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
	return aro::UNSUPPORTED~;
}

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

<* Next type description; END when the string is exhausted. *>
fn TypeDescription? TypeIterator.next(&self)
{
	return aro::UNSUPPORTED~;
}

<*
 Builtins.createType: builds the QualType for `desc`. For a VECTOR spec the
 element type is read from `it` (the element's suffixes apply to the vector).
*>
fn QualType create_type(Compilation* comp, TypeDescription desc, TypeIterator* it)
{
	return type_store::INVALID;
}

<* Builtins.createBuiltin: the function type for a whole param_str (variadic if is_var_args). *>
fn QualType create_builtin(Compilation* comp, String param_str)
{
	return type_store::INVALID;
}
