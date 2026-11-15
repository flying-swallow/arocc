// Hand-written test table in the exact generated layout of
// tools/builtins_schema.md ("Generated table layout"), standing in for
// bazel-bin/builtin_defs/common.c3 until the generator fills the real tables.
// Source-derived: entries copied from src/aro/Builtins/common.def (lines 51,
// 487, 491, 992, 1110, 2385, 3003, 4467); attribute bits computed by hand from
// the Attributes bit table (eval_args 0x10000 is the default).
// _Exit/_exit collide when uppercased, so (as in the real common table) they
// get no TAG_ constant.
module aro::builtin_defs::sample;
import aro::builtin_properties;

const BuiltinGroup GROUP = COMMON;
const ushort COUNT = 8;
const usz SHORTEST_NAME = 3;
const usz LONGEST_NAME = 22;

const String[] NAMES = {
	"_Exit",
	"__builtin_abs",
	"__builtin_c23_va_start",
	"__builtin_ms_va_start",
	"__builtin_va_start",
	"_exit",
	"abs",
	"printf",
};

const BuiltinRecord[] RECORDS = {
	{ "vi", ALL_LANGUAGES, STDLIB, (Attributes)0x10040, "" },
	{ "ii", ALL_LANGUAGES, NONE, (Attributes)0x90024, "" },
	{ "vA.", C23_LANG, NONE, (Attributes)0x10008, "" },
	{ "v.", ALL_LANGUAGES, NONE, (Attributes)0x10008, "" },
	{ "vA.", ALL_LANGUAGES, NONE, (Attributes)0x10008, "" },
	{ "vi", ALL_GNU_LANGUAGES, UNISTD, (Attributes)0x10040, "" },
	{ "ii", ALL_LANGUAGES, STDLIB, (Attributes)0x10044, "" },
	{ "icC*.", ALL_LANGUAGES, STDIO, (Attributes)0x10040, "" },
};

const BuiltinTag TAG___BUILTIN_ABS = { .group = COMMON, .index = 1 };
const BuiltinTag TAG___BUILTIN_C23_VA_START = { .group = COMMON, .index = 2 };
const BuiltinTag TAG___BUILTIN_MS_VA_START = { .group = COMMON, .index = 3 };
const BuiltinTag TAG___BUILTIN_VA_START = { .group = COMMON, .index = 4 };
const BuiltinTag TAG_ABS = { .group = COMMON, .index = 6 };
const BuiltinTag TAG_PRINTF = { .group = COMMON, .index = 7 };
