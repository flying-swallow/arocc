// Driver argument catalogue. Members are edited by hand; `supported` bits (here and on
// diagnostics::Option / OptionGroup) are refreshed by tools/gen_driver_arguments/gen_driver_arguments.py
// (last run against GCC fceddda853f, LLVM 55b0b8fa1).
module aro::frontend::c::driver_arguments;

<* Which real compiler drivers accept a spelling. Neither bit set: an aro extension. *>
bitstruct Supported : char
{
	bool clang : 0;
	bool gcc : 1;
}

<* How an argument carries its value. *>
enum ArgKind : char
{
	<* No value: `-fblocks`. *>
	FLAG,
	<* Value in the next argument: `-o file`. *>
	SEPARATE,
	<* Value attached to the spelling: `-O2`, `-Wvla`. *>
	JOINED,
	<* Attached, or the next argument when nothing is attached: `-Ifoo`, `-I foo`. *>
	JOINED_OR_SEPARATE,
	<* Value after an `=`, spelled without it: `-std` matches `-std=c11`. *>
	EQUALS,
}

<* Every argument spelling aro's driver accepts. `toolchain` arguments (target,
   paths, linker, output and diagnostic presentation) are never filtered by --emulate. *>
enum DriverArgument : ushort (String[] args, ArgKind kind, Supported supported, bool toolchain)
{
	ASSEMBLE { { "-S", "--assemble" }, FLAG, { .clang = true, .gcc = true }, false },
	COMMENTS { { "-C", "--comments" }, FLAG, { .clang = true, .gcc = true }, false },
	COMPILE { { "-c", "--compile" }, FLAG, { .clang = true, .gcc = true }, false },
	COMMENTS_IN_MACROS { { "-CC", "--comments-in-macros" }, FLAG, { .clang = true, .gcc = true }, false },
	CODEGEN_TODO_REPORT { { "--codegen-todo-report" }, FLAG, {}, false },
	D { { "-D" }, JOINED_OR_SEPARATE, { .clang = true, .gcc = true }, false },
	DARWIN_TARGET_VARIANT_TRIPLE { { "-darwin-target-variant-triple" }, SEPARATE, { .clang = true, .gcc = true }, false },
	DD { { "-dD" }, FLAG, { .clang = true, .gcc = true }, false },
	DEPENDENCIES { { "-M", "--dependencies" }, FLAG, { .clang = true, .gcc = true }, false },
	DM { { "-dM" }, FLAG, { .clang = true, .gcc = true }, false },
	DN { { "-dN" }, FLAG, { .clang = true, .gcc = true }, false },
	E { { "-E" }, FLAG, { .clang = true, .gcc = true }, false },
	EMBED_DIR { { "--embed-dir" }, SEPARATE, {}, true },
	EMBED_DIR_EQ { { "--embed-dir" }, EQUALS, { .gcc = true }, true },
	EMULATE_EQ { { "--emulate" }, EQUALS, {}, false },
	F { { "-F" }, SEPARATE, { .clang = true, .gcc = true }, true },
	APPLE_KEXT { { "-fapple-kext" }, FLAG, { .clang = true }, false },
	BLOCKS { { "-fblocks" }, FLAG, { .clang = true }, false },
	CARET_DIAGNOSTICS { { "-fcaret-diagnostics" }, FLAG, { .clang = true }, true },
	CHAR8_T { { "-fchar8_t" }, FLAG, { .clang = true }, false },
	COLOR_DIAGNOSTICS { { "-fcolor-diagnostics" }, FLAG, { .clang = true }, true },
	COMMON { { "-fcommon" }, FLAG, { .clang = true, .gcc = true }, false },
	DECLSPEC { { "-fdeclspec" }, FLAG, { .clang = true }, false },
	DIGRAPHS { { "-fdigraphs" }, FLAG, { .clang = true }, false },
	DOLLARS_IN_IDENTIFIERS { { "-fdollars-in-identifiers" }, FLAG, { .clang = true, .gcc = true }, false },
	EXPERIMENTAL_BOUNDS_SAFETY { { "-fexperimental-bounds-safety" }, FLAG, {}, false },
	FP_EVAL_METHOD_EQ { { "-ffp-eval-method" }, EQUALS, { .clang = true }, false },
	FREESTANDING { { "-ffreestanding" }, FLAG, { .clang = true, .gcc = true }, false },
	GNU_INLINE_ASM { { "-fgnu-inline-asm" }, FLAG, { .clang = true }, false },
	GNUC_VERSION_EQ { { "-fgnuc-version" }, EQUALS, { .clang = true }, false },
	HOSTED { { "-fhosted" }, FLAG, { .clang = true, .gcc = true }, false },
	INTEGRATED_AS { { "-fintegrated-as" }, FLAG, { .clang = true }, true },
	LTO { { "-flto" }, JOINED, { .clang = true, .gcc = true }, false },
	MACRO_BACKTRACE_LIMIT_EQ { { "-fmacro-backtrace-limit" }, EQUALS, { .clang = true }, true },
	MS_EXTENSIONS { { "-fms-extensions" }, FLAG, { .clang = true, .gcc = true }, false },
	NATIVE_HALF_ARGUMENTS_AND_RETURNS { { "-fnative-half-arguments-and-returns" }, FLAG, {}, false },
	NATIVE_HALF_TYPE { { "-fnative-half-type" }, FLAG, {}, false },
	NO_BLOCKS { { "-fno-blocks" }, FLAG, { .clang = true }, false },
	NO_CARET_DIAGNOSTICS { { "-fno-caret-diagnostics" }, FLAG, { .clang = true }, true },
	NO_CHAR8_T { { "-fno-char8_t" }, FLAG, { .clang = true }, false },
	NO_COLOR_DIAGNOSTICS { { "-fno-color-diagnostics" }, FLAG, { .clang = true }, true },
	NO_COMMON { { "-fno-common" }, FLAG, { .clang = true, .gcc = true }, false },
	NO_DECLSPEC { { "-fno-declspec" }, FLAG, { .clang = true }, false },
	NO_DIGRAPHS { { "-fno-digraphs" }, FLAG, { .clang = true }, false },
	NO_DOLLARS_IN_IDENTIFIERS { { "-fno-dollars-in-identifiers" }, FLAG, { .clang = true, .gcc = true }, false },
	NO_EXPERIMENTAL_BOUNDS_SAFETY { { "-fno-experimental-bounds-safety" }, FLAG, {}, false },
	NO_GNU_INLINE_ASM { { "-fno-gnu-inline-asm" }, FLAG, { .clang = true }, false },
	NO_INTEGRATED_AS { { "-fno-integrated-as" }, FLAG, { .clang = true }, true },
	NO_LTO { { "-fno-lto" }, FLAG, { .clang = true, .gcc = true }, false },
	NO_MS_EXTENSIONS { { "-fno-ms-extensions" }, FLAG, { .clang = true, .gcc = true }, false },
	NO_PIC_LARGE { { "-fno-PIC" }, FLAG, { .clang = true, .gcc = true }, false },
	NO_PIC { { "-fno-pic" }, FLAG, { .clang = true, .gcc = true }, false },
	NO_PIE_LARGE { { "-fno-PIE" }, FLAG, { .clang = true, .gcc = true }, false },
	F_NO_PIE { { "-fno-pie" }, FLAG, { .clang = true, .gcc = true }, false },
	NO_ROPI { { "-fno-ropi" }, FLAG, { .clang = true }, false },
	NO_RWPI { { "-fno-rwpi" }, FLAG, { .clang = true }, false },
	NO_SHORT_ENUMS { { "-fno-short-enums" }, FLAG, { .clang = true, .gcc = true }, false },
	UNSIGNED_CHAR { { "-funsigned-char", "-fno-signed-char" }, FLAG, { .clang = true, .gcc = true }, false },
	NO_SYNTAX_ONLY { { "-fno-syntax-only" }, FLAG, { .gcc = true }, true },
	SIGNED_CHAR { { "-fsigned-char", "-fno-unsigned-char" }, FLAG, { .clang = true, .gcc = true }, false },
	NO_USE_LINE_DIRECTIVES { { "-fno-use-line-directives" }, FLAG, { .clang = true }, true },
	NO_WHOLE_PROGRAM { { "-fno-whole-program" }, FLAG, { .clang = true, .gcc = true }, false },
	PIC_LARGE { { "-fPIC" }, FLAG, { .clang = true, .gcc = true }, false },
	PIC { { "-fpic" }, FLAG, { .clang = true, .gcc = true }, false },
	PIE_LARGE { { "-fPIE" }, FLAG, { .clang = true, .gcc = true }, false },
	F_PIE { { "-fpie" }, FLAG, { .clang = true, .gcc = true }, false },
	RANDOM_SEED_EQ { { "-frandom-seed" }, EQUALS, { .clang = true, .gcc = true }, false },
	ROPI { { "-fropi" }, FLAG, { .clang = true }, false },
	RWPI { { "-frwpi" }, FLAG, { .clang = true }, false },
	SIGNALING_NANS { { "-fsignaling-nans", "-fno-signaling-nans" }, FLAG, { .gcc = true }, false },
	SHORT_ENUMS { { "-fshort-enums" }, FLAG, { .clang = true, .gcc = true }, false },
	SYNTAX_ONLY { { "-fsyntax-only" }, FLAG, { .clang = true, .gcc = true }, true },
	USE_LD_EQ { { "-fuse-ld" }, EQUALS, { .clang = true, .gcc = true }, true },
	USE_LINE_DIRECTIVES { { "-fuse-line-directives" }, FLAG, { .clang = true }, true },
	VISIBILITY_EQ { { "-fvisibility" }, EQUALS, { .clang = true, .gcc = true }, false },
	VISIBILITY_DEFAULT { { "-fvisibility=default" }, FLAG, { .clang = true, .gcc = true }, false },
	VISIBILITY_HIDDEN { { "-fvisibility=hidden" }, FLAG, { .clang = true, .gcc = true }, false },
	VISIBILITY_PROTECTED { { "-fvisibility=protected" }, FLAG, { .clang = true, .gcc = true }, false },
	WHOLE_PROGRAM { { "-fwhole-program" }, FLAG, { .clang = true, .gcc = true }, false },
	WRAPV { { "-fwrapv", "-fno-strict-overflow" }, FLAG, { .clang = true, .gcc = true }, false },
	NO_WRAPV { { "-fno-wrapv", "-fstrict-overflow" }, FLAG, { .clang = true, .gcc = true }, false },
	VECTORIZE { { "-ftree-vectorize", "-fvectorize" }, FLAG, { .clang = true, .gcc = true }, false },
	NO_VECTORIZE { { "-fno-tree-vectorize", "-fno-vectorize" }, FLAG, { .clang = true, .gcc = true }, false },
	G { { "-g" }, FLAG, { .clang = true, .gcc = true }, false },
	G0 { { "-g0" }, FLAG, { .clang = true, .gcc = true }, false },
	GCODEVIEW { { "-gcodeview" }, FLAG, { .clang = true, .gcc = true }, false },
	GDWARF { { "-gdwarf" }, FLAG, { .clang = true, .gcc = true }, false },
	GDWARF_2 { { "-gdwarf-2" }, FLAG, { .clang = true, .gcc = true }, false },
	GDWARF_3 { { "-gdwarf-3" }, FLAG, { .clang = true, .gcc = true }, false },
	GDWARF_4 { { "-gdwarf-4" }, FLAG, { .clang = true, .gcc = true }, false },
	GDWARF_5 { { "-gdwarf-5" }, FLAG, { .clang = true, .gcc = true }, false },
	GDWARF32 { { "-gdwarf32" }, FLAG, { .clang = true, .gcc = true }, false },
	GDWARF64 { { "-gdwarf64" }, FLAG, { .clang = true, .gcc = true }, false },
	H { { "-h" }, FLAG, { .gcc = true }, true },
	HELP { { "--help" }, FLAG, { .clang = true, .gcc = true }, true },
	I { { "-I" }, JOINED_OR_SEPARATE, { .clang = true, .gcc = true }, false },
	IDIRAFTER { { "-idirafter" }, SEPARATE, { .clang = true, .gcc = true }, false },
	IFRAMEWORK { { "-iframework" }, SEPARATE, { .clang = true }, true },
	IMACROS { { "-imacros" }, SEPARATE, { .clang = true, .gcc = true }, false },
	INCLUDE { { "-include" }, SEPARATE, { .clang = true, .gcc = true }, false },
	IQUOTE { { "-iquote" }, SEPARATE, { .clang = true, .gcc = true }, false },
	ISYSROOT { { "-isysroot" }, JOINED_OR_SEPARATE, { .clang = true, .gcc = true }, true },
	ISYSTEM { { "-isystem" }, SEPARATE, { .clang = true, .gcc = true }, false },
	LIBRARY_DIR { { "-L" }, JOINED_OR_SEPARATE, { .clang = true, .gcc = true }, false },
	LIBRARY { { "-l" }, JOINED_OR_SEPARATE, { .clang = true, .gcc = true }, false },
	LD_PATH_EQ { { "--ld-path" }, EQUALS, { .clang = true }, true },
	MABICALLS { { "-mabicalls" }, FLAG, { .clang = true }, false },
	MCMODEL_EQ { { "-mcmodel" }, EQUALS, { .clang = true, .gcc = true }, false },
	MCPU { { "-mcpu" }, SEPARATE, {}, false },
	MCPU_EQ { { "-mcpu" }, EQUALS, { .clang = true, .gcc = true }, false },
	WRITE_DEPENDENCIES { { "-MD", "--write-dependencies" }, FLAG, { .clang = true, .gcc = true }, false },
	MDYNAMIC_NO_PIC { { "-mdynamic-no-pic" }, FLAG, { .clang = true }, false },
	MF { { "-MF" }, JOINED_OR_SEPARATE, { .clang = true, .gcc = true }, false },
	MKERNEL { { "-mkernel" }, FLAG, { .clang = true }, false },
	MNO_ABICALLS { { "-mno-abicalls" }, FLAG, { .clang = true }, false },
	MV { { "-MV" }, FLAG, { .clang = true }, true },
	NO_LINE_COMMANDS { { "-P", "--no-line-commands" }, FLAG, { .clang = true, .gcc = true }, false },
	NO_PIE { { "-no-pie" }, FLAG, { .clang = true, .gcc = true }, false },
	NO_STANDARD_INCLUDES { { "-nostdinc", "--no-standard-includes" }, FLAG, { .clang = true, .gcc = true }, false },
	NOBUILTININC { { "-nobuiltininc" }, FLAG, { .clang = true }, true },
	NODEFAULTLIBS { { "-nodefaultlibs" }, FLAG, { .clang = true, .gcc = true }, false },
	NOLIBC { { "-nolibc" }, FLAG, { .clang = true, .gcc = true }, false },
	NOPIE { { "-nopie" }, FLAG, { .clang = true }, false },
	NOSTARTFILES { { "-nostartfiles" }, FLAG, { .clang = true, .gcc = true }, false },
	NOSTDLIB { { "-nostdlib" }, FLAG, { .clang = true, .gcc = true }, false },
	NOSTDLIBINC { { "-nostdlibinc" }, FLAG, { .clang = true }, true },
	OPTIMIZE { { "-O" }, JOINED, { .clang = true, .gcc = true }, false },
	OUTPUT { { "-o" }, SEPARATE, { .clang = true, .gcc = true }, false },
	PEDANTIC { { "-pedantic" }, FLAG, { .clang = true, .gcc = true }, false },
	PEDANTIC_ERRORS { { "-pedantic-errors" }, FLAG, { .clang = true, .gcc = true }, false },
	PIE { { "-pie" }, FLAG, { .clang = true, .gcc = true }, false },
	PTHREAD { { "-pthread" }, FLAG, { .clang = true, .gcc = true }, false },
	R { { "-r" }, FLAG, { .clang = true, .gcc = true }, false },
	RDYNAMIC { { "-rdynamic" }, FLAG, { .clang = true, .gcc = true }, false },
	RESOURCE_DIR { { "-resource-dir" }, SEPARATE, { .clang = true }, true },
	LONG_RESOURCE_DIR_EQ { { "--resource-dir" }, EQUALS, {}, true },
	RESOURCE_DIR_EQ { { "-resource-dir" }, EQUALS, { .clang = true }, true },
	RPATH { { "-rpath" }, SEPARATE, { .clang = true }, true },
	RTLIB_EQ { { "--rtlib" }, EQUALS, { .clang = true }, true },
	STRIP { { "-s" }, FLAG, { .clang = true, .gcc = true }, false },
	SHARED { { "-shared" }, FLAG, { .clang = true, .gcc = true }, false },
	SHARED_LIBGCC { { "-shared-libgcc" }, FLAG, { .clang = true, .gcc = true }, false },
	STATIC { { "-static" }, FLAG, { .clang = true, .gcc = true }, false },
	STATIC_LIBGCC { { "-static-libgcc" }, FLAG, { .clang = true, .gcc = true }, false },
	STATIC_PIE { { "-static-pie" }, FLAG, { .clang = true, .gcc = true }, false },
	STD { { "-std" }, SEPARATE, {}, false },
	STD_EQ { { "-std" }, EQUALS, { .clang = true, .gcc = true }, false },
	SYSROOT { { "--sysroot" }, SEPARATE, { .clang = true, .gcc = true }, true },
	SYSROOT_EQ { { "--sysroot" }, EQUALS, { .clang = true, .gcc = true }, true },
	LONG_TARGET { { "--target" }, SEPARATE, {}, true },
	TARGET { { "-target" }, SEPARATE, { .clang = true }, true },
	TARGET_EQ { { "--target" }, EQUALS, { .clang = true }, true },
	U { { "-U" }, JOINED_OR_SEPARATE, { .clang = true, .gcc = true }, false },
	UNDEF { { "-undef" }, FLAG, { .clang = true, .gcc = true }, false },
	UNWINDLIB_EQ { { "--unwindlib" }, EQUALS, { .clang = true }, true },
	VERBOSE_AST { { "--verbose-ast" }, FLAG, {}, false },
	VERBOSE_IR { { "--verbose-ir" }, FLAG, {}, false },
	VERBOSE_LINKER_ARGS { { "--verbose-linker-args" }, FLAG, {}, false },
	VERBOSE_PP { { "--verbose-pp" }, FLAG, {}, false },
	VERIFY_IR { { "--verify-ir" }, FLAG, {}, false },
	VERSION { { "--version" }, FLAG, { .clang = true, .gcc = true }, true },
	W { { "-W" }, JOINED, { .clang = true, .gcc = true }, false },
	NO_WARNINGS { { "-w" }, FLAG, { .clang = true, .gcc = true }, false },
	WERROR { { "-Werror" }, FLAG, { .clang = true, .gcc = true }, false },
	WERROR_EQ { { "-Werror" }, EQUALS, { .clang = true, .gcc = true }, false },
	WEVERYTHING { { "-Weverything" }, FLAG, { .clang = true }, false },
	WFATAL_ERRORS { { "-Wfatal-errors" }, FLAG, { .clang = true, .gcc = true }, false },
	WNO { { "-Wno-" }, JOINED, { .clang = true, .gcc = true }, false },
	WNO_ERROR { { "-Wno-error" }, FLAG, { .clang = true, .gcc = true }, false },
	WNO_ERROR_EQ { { "-Wno-error" }, EQUALS, { .clang = true, .gcc = true }, false },
	WNO_EVERYTHING { { "-Wno-everything" }, FLAG, { .clang = true }, false },
	WNO_FATAL_ERRORS { { "-Wno-fatal-errors" }, FLAG, { .clang = true, .gcc = true }, false },
	WNO_SYSTEM_HEADERS { { "-Wno-system-headers" }, FLAG, { .clang = true, .gcc = true }, false },
	WP_V { { "-Wp,-v" }, FLAG, { .clang = true, .gcc = true }, false },
	WSYSTEM_HEADERS { { "-Wsystem-headers" }, FLAG, { .clang = true, .gcc = true }, false },
	X_LANGUAGE { { "-x" }, JOINED_OR_SEPARATE, { .clang = true, .gcc = true }, false },
	X86_64_SPILL_ALL { { "--x86-64-spill-all" }, FLAG, {}, false },
	SCALAR_VECTOR_EXT { { "--scalar-vector-ext" }, FLAG, {}, false },
}

faultdef UNKNOWN_ARGUMENT;

<* The argument `arg` spells. Exact spellings win over the longest joined prefix
   (`-fvisibility=default` over `-fvisibility` EQUALS). The caller consumes the value
   (`joined_value`, or the next argument for SEPARATE kinds) and applies it. *>
fn DriverArgument? match(String arg)
{
	$foreach $argument : DriverArgument::values:
		$if $argument.kind != EQUALS:
			$foreach $spelling : $argument.args:
				if (arg == $spelling) return $argument;
			$endforeach
		$endif
	$endforeach
	DriverArgument best;
	usz best_len = 0;
	$foreach $argument : DriverArgument::values:
		$switch $argument.kind:
			$case JOINED:
			$case JOINED_OR_SEPARATE:
				$foreach $spelling : $argument.args:
					if ($spelling.len > best_len && arg.starts_with($spelling))
					{
						best = $argument;
						best_len = $spelling.len;
					}
				$endforeach
			$case EQUALS:
				$foreach $spelling : $argument.args:
					if ($spelling.len + 1 > best_len && arg.len > $spelling.len && arg[$spelling.len] == '=' && arg.starts_with($spelling))
					{
						best = $argument;
						best_len = $spelling.len + 1;
					}
				$endforeach
			$default:
		$endswitch
	$endforeach
	if (best_len == 0) return UNKNOWN_ARGUMENT~;
	return best;
}

<* The value attached to a spelling of `self` in `arg` (empty if none); EQUALS skips the `=`. *>
fn String DriverArgument.joined_value(self, String arg)
{
	usz skip = self.kind == EQUALS ? 1 : 0;
	foreach (spelling : self.args)
	{
		if (arg.len >= spelling.len + skip && arg.starts_with(spelling)) return arg[spelling.len + skip..];
	}
	return "";
}

<* Whether a bare spelling of `self` takes the next argument as its value. *>
fn bool DriverArgument.takes_next(self, String arg)
{
	switch (self.kind)
	{
		case SEPARATE: return true;
		case JOINED_OR_SEPARATE: return self.joined_value(arg).len == 0;
		default: return false;
	}
}
