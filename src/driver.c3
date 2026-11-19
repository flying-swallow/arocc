// Reusable command-line driver for the Aro CLI, including frontend and backend
// orchestration.
module aro::driver;
import aro::driver_options;
import aro::compilation, aro::target, aro::code_gen_options, aro::toolchain, aro::lang_opts, aro::system_defaults;
import aro::toolchain::discovery;
import aro::source, aro::preprocessor, aro::predefined_macros, aro::parser, aro::parser_frontend, aro::tree;
import aro::driver_exec, aro::driver_tempfiles;
import aro::backend::ir, aro::backend::ir_opt, aro::backend::object, aro::codegen;
import aro::host_process;
import aro::include_search, aro::dep_file, aro::diagnostics, aro::pragma;
import aro::pragmas::gcc, aro::pragmas::once, aro::pragmas::message, aro::pragmas::pack;
import aro::toolchain::gcc_version, aro::toolchain::multilib;
import aro::value_interner;
import std::io, std::io::file, std::io::path, std::io::os, std::os::env;
import std::collections::list;
import std::core::dstring, std::core::string;

excuse MISSING_ARGUMENT;
excuse INVALID_ARGUMENT;
excuse INVALID_TARGET;
excuse CLI_INCLUDE_NOT_FOUND;

struct ArgumentResult
{
	ParseAction action; uint input_count;
}

struct PicPolicy
{
	PicLevel level; bool is_pie;
}

struct WholeProgram
{
	ir::Ir program;
	List{String} origins;
}

fn void WholeProgram.init(&self, Allocator allocator, value_interner::Interner* interner)
{
	self.program.init(allocator, interner);
	self.origins.init(allocator);
}

fn void WholeProgram.free(&self)
{
	self.program.free();
	self.origins.free();
}

const String USAGE_FORMAT = "Usage %s: [options] file..\n\nGeneral options:\n  --help      Print this message\n  --version   Print aro version\n\nPreprocessor options:\n  -C                      Do not discard comments\n  -CC                     Do not discard comments, including in macro expansions\n  -dM                     Output #define directives for all the macros defined during the execution of the preprocessor\n  -dD                     Like -dM except that it outputs both the #define directives and the result of preprocessing\n  -dN                     Like -dD, but emit only the macro names, not their expansions.\n  -D <macro>=<value>      Define <macro> to <value> (defaults to 1)\n  -E                      Only run the preprocessor\n  -fdollars-in-identifiers\n                          Allow '$' in identifiers\n  -fno-dollars-in-identifiers\n                          Disallow '$' in identifiers\n  -M                      Output dependency file instead of preprocessing result\n  -MD                     Like -M except -E is not implied\n  -MF <file>              Write dependency file to <file>\n  -MV                     Use NMake/Jom format for dependency file\n  -P, --no-line-commands  Disable linemarker output in -E mode\n\nCompile options:\n  -c, --compile           Only run preprocess, compile, and assemble steps\n  -darwin-target-variant-triple\n                          Specify the darwin target variant triple\n  -fapple-kext            Use Apple's kernel extensions ABI\n  -fexperimental-bounds-safety\n                          Enable experimental clang-style bounds safety attributes (INCOMPLETE)\n  -fno-experimental-bounds-safety\n                          Disable experimental clang-style bounds safety attributes\n  -fchar8_t               Enable char8_t (enabled by default in C23 and later)\n  -fno-char8_t            Disable char8_t (disabled by default for pre-C23)\n  -fcolor-diagnostics     Enable colors in diagnostics\n  -fno-color-diagnostics  Disable colors in diagnostics\n  -fcommon                Place uninitialized global variables in a common block\n  -fno-common             Place uninitialized global variables in the BSS section of the object file\n  -fwhole-program         Compile all inputs into one IR module and object; forces IR generation at every -O level\n  -fno-whole-program      Compile each input translation unit separately\n  -fintegrated-as         Use the integrated object emitter for IR output (default on x86_64 Linux)\n  -fno-integrated-as      Use the system assembler for IR output\n  -fdeclspec              Enable support for __declspec attributes\n  -fgnuc-version=<value>  Controls value of __GNUC__ and related macros. Set to 0 or empty to disable them.\n  -fno-declspec           Disable support for __declspec attributes\n  -ffp-eval-method=[source|double|extended]\n                          Evaluation method to use for floating-point arithmetic\n  -ffreestanding          Compilation in a freestanding environment\n  -fgnu-inline-asm        Enable GNU style inline asm (default: enabled)\n  -fno-gnu-inline-asm     Disable GNU style inline asm\n  -fhosted                Compilation in a hosted environment\n  -fms-extensions         Enable support for Microsoft extensions\n  -fno-ms-extensions      Disable support for Microsoft extensions\n  -g                      Generate debug information\n  -fmacro-backtrace-limit=<limit>\n                          Set limit on how many macro expansion traces are shown in errors (default 6)\n  -fnative-half-type      Use the native half type for __fp16 instead of promoting to float\n  -fnative-half-arguments-and-returns\n                          Allow half-precision function arguments and return values\n  -fpic                   Generate position-independent code (PIC) suitable for use in a shared library, if supported for the target machine\n  -fPIC                   Similar to -fpic but avoid any limit on the size of the global offset table\n  -fpie                   Similar to -fpic, but the generated position-independent code can only be linked into executables\n  -fPIE                   Similar to -fPIC, but the generated position-independent code can only be linked into executables\n  -frwpi                  Generate read-write position independent code (ARM only)\n  -fno-rwpi               Disable generate read-write position independent code (ARM only).\n  -fropi                  Generate read-only position independent code (ARM only)\n  -fno-ropi               Disable generate read-only position independent code (ARM only).\n  -fshort-enums           Use the narrowest possible integer type for enums\n  -fno-short-enums        Use \"int\" as the tag type for enums\n  -fsigned-char           \"char\" is signed\n  -fno-signed-char        \"char\" is unsigned\n  -fsyntax-only           Only run the preprocessor, parser, and semantic analysis stages\n  -funsigned-char         \"char\" is unsigned\n  -fno-unsigned-char      \"char\" is signed\n  -fuse-line-directives   Use `#line <num>` linemarkers in preprocessed output\n  -fno-use-line-directives\n                          Use `# <num>` linemarkers in preprocessed output\n  -fvisibility=[default|hidden|internal|protected]\n                          Set the default ELF image symbol visibility to the specified option—all symbols are marked with this unless overridden within the code\n  -fblocks                Enable support for clang's Blocks language extension\n  -fno-blocks             Disable support for clang's Blocks language extension\n  -iquote <dir>           Add directory to QUOTE include search path\n  -I <dir>                Add directory to include search path\n  -idirafter <dir>        Add directory to AFTER include search path\n  -isystem <dir>          Add directory to SYSTEM include search path\n  -F <dir>                Add directory to macOS framework search path\n  -iframework <dir>       Add directory to SYSTEM macOS framework search path\n  --embed-dir=<dir>       Add directory to `#embed` search path\n  --emulate=[clang|gcc|msvc]\n                          Select which C compiler to emulate (default clang)\n  -imacros <file>         Include macros from <file> before parsing\n  -include <file>         Process <file> as if `#include \"file\"` appeared as the first line of the primary source file.\n  -mabicalls              Enable SVR4-style position-independent code (Mips only)\n  -mno-abicalls           Disable SVR4-style position-independent code (Mips only)\n  -mcmodel=<code-model>   Generate code for the given code model\n  -mcpu [cpu]             Specify target CPU and feature set\n  -mkernel                Enable kernel development mode\n  -nobuiltininc           Do not search the compiler's builtin directory for include files\n  -resource-dir <dir>     Override the path to the compiler's builtin resource directory\n  -nostdinc, --no-standard-includes\n                          Do not search the standard system directories or compiler builtin directories for include files.\n  -nostdlibinc            Do not search the standard system directories for include files, but do search compiler builtin include directories\n  -o <file>               Write output to <file>\n  -pedantic               Warn on language extensions\n  -pedantic-errors        Error on language extensions\n  --rtlib=<arg>           Compiler runtime library to use (libgcc or compiler-rt)\n  -std=<standard>         Specify language standard\n  -S, --assemble          Only run preprocess and compilation steps\n  --sysroot=<dir>         Use dir as the logical root directory for headers and libraries (not fully implemented)\n  --target=<value>        Generate code for the given target\n  -U <macro>              Undefine <macro>\n  -undef                  Do not predefine any system-specific macros. Standard predefined macros remain defined.\n  -w                      Ignore all warnings\n  -Werror                 Treat all warnings as errors\n  -Werror=<warning>       Treat warning as error\n  -W<warning>             Enable the specified warning\n  -Wno-<warning>          Disable the specified warning\n\nLink options:\n  -fuse-ld=[bfd|gold|lld|mold]\n                          Use specific linker\n  -nodefaultlibs          Do not use the standard system libraries when linking.\n  -nolibc                 Do not use the C library or system libraries tightly coupled with it when linking.\n  -nostdlib               Do not use the standard system startup files or libraries when linking\n  -nostartfiles           Do not use the standard system startup files when linking.\n  -pie                    Produce a dynamically linked position independent executable on targets that support it.\n  --ld-path=<path>        Use linker specified by <path>\n  -r                      Produce a relocatable object as output.\n  -rdynamic               Pass the flag -export-dynamic to the ELF linker, on targets that support it.\n  -s                      Remove all symbol table and relocation information from the executable.\n  -shared                 Produce a shared object which can then be linked with other objects to form an executable.\n  -shared-libgcc          On systems that provide libgcc as a shared library, force the use of the shared version\n  -static                 On systems that support dynamic linking, this overrides -pie and prevents linking with the shared libraries.\n  -static-libgcc          On systems that provide libgcc as a shared library, force the use of the static version\n  -static-pie             Produce a static position independent executable on targets that support it.\n  --unwindlib=<arg>       Unwind library to use (\"none\", \"libgcc\", or \"libunwind\") If not specified, will match runtime library\n\nDebug options:\n  --verbose-ast           Dump produced AST to stdout\n  --verbose-pp            Dump preprocessor state\n  --verbose-ir            Dump ir to stdout\n  --verbose-linker-args   Dump linker args to stdout\n  --codegen-todo-report  Report all unsupported codegen TODOs (not supported with -fwhole-program)\n  --x86-64-spill-all      Spill all values in x86-64 lowering\n\n\n";

fn String usage_text(Allocator a, String program_name)
{
	DString out;
	out.init(a);
	out.appendf(USAGE_FORMAT, program_name)!!;
	String result = out.str_view().copy(a);
	out.free();
	return result;
}

fn String version_text(Allocator a)
{
	DString out;
	out.init(a);
	out.appendf("%s\n", aro::VERSION)!!;
	String result = out.str_view().copy(a);
	out.free();
	return result;
}

fn bool parse_u32_decimal(String s, uint* out)
{
	if (s.len == 0) return false;
	usz i = 0;
	bool negative = false;
	if (s[0] == '+' || s[0] == '-')
	{
		negative = s[0] == '-';
		i = 1;
	}
	if (i == s.len || s[i] == '_' || s[s.len - 1] == '_') return false;
	ulong acc = 0;
	bool previous_underscore = false;
	for (; i < s.len; i++)
	{
		char c = s[i];
		if (c == '_')
		{
			if (previous_underscore) return false;
			previous_underscore = true;
			continue;
		}
		if (c < '0' || c > '9') return false;
		previous_underscore = false;
		ulong digit = (ulong)(c - '0');
		if (acc > (0xFFFF_FFFF - digit) / 10) return false;
		acc = acc * 10 + digit;
	}
	if (negative && acc != 0) return false;
	*out = (uint)acc;
	return true;
}

fn void parse_warning_option(DriverOptions* opts, String arg)
{
	if (arg == "-Werror" || arg == "-Wno-error" || arg == "-Wfatal-errors" || arg == "-Wno-fatal-errors" || arg == "-Weverything" || arg == "-Wno-everything" || arg == "-Wsystem-headers" || arg == "-Wno-system-headers") return;
	if (arg.starts_with("-Werror="))
	{
		opts.warning_policies.push(
		{
			.name = arg[8..], .mode = ERROR
		}
		); return;
	}
	if (arg.starts_with("-Wno-error="))
	{
		opts.warning_policies.push(
		{
			.name = arg[11..], .mode = WARNING
		}
		); return;
	}
	if (arg.starts_with("-Wno-"))
	{
		opts.warning_policies.push(
		{
			.name = arg[5..], .mode = OFF
		}
		); return;
	}
	opts.warning_policies.push(
	{
		.name = arg[2..], .mode = WARNING
	}
	);
}

<* Parse one bounded group of options to keep driver argument parsing shallow. *>
fn bool? parse_frontend_flag_set_a(DriverOptions* opts, String arg, Diagnostics* sink)
{
	if (arg == "-E")
	{
		opts.only_preprocess = true;
	}
	else if (arg == "-fsyntax-only")
	{
		opts.only_syntax = true;
	}
	else if (arg == "-fno-syntax-only")
	{
		opts.only_syntax = false;
	}
	else if (arg == "-c" || arg == "--compile")
	{
		opts.only_compile = true;
	}
	else if (arg == "-S" || arg == "--assemble")
	{
		opts.only_preprocess_and_compile = true;
	}
	else if (arg == "-P" || arg == "--no-line-commands")
	{
		opts.line_commands = false;
	}
	else if (arg == "-fuse-line-directives")
	{
		opts.use_line_directives = true;
	}
	else if (arg == "-fno-use-line-directives")
	{
		opts.use_line_directives = false;
	}
	else if (arg == "-undef")
	{
		opts.no_system_defines = true;
	}
	else if (arg == "-C" || arg == "--comments")
	{
		opts.preserve_comments = true;
	}
	else if (arg == "-CC" || arg == "--comments-in-macros")
	{
		opts.preserve_comments = true; opts.preserve_comments_in_macros = true;
	}
	else if (arg == "--verbose-ast")
	{
		opts.verbose_ast = true;
	}
	else if (arg == "--verbose-pp")
	{
		opts.verbose_pp = true;
	}
	else if (arg == "--verbose-ir")
	{
		opts.verbose_ir = true;
	}
	else if (arg == "--verify-ir")
	{
		opts.verify_ir = true;
	}
	else if (arg == "--codegen-todo-report")
	{
		opts.codegen_todo_report = true;
	}
	else if (arg == "--x86-64-spill-all")
	{
		opts.x86_64_spill_all = true;
	}
	else if (arg == "--verbose-linker-args")
	{
		opts.verbose_linker_args = true;
	}
	else
	{
		return false;
	}
	return true;
}

<* Parse one bounded group of options to keep driver argument parsing shallow. *>
fn bool? parse_frontend_flag_set_b(DriverOptions* opts, String arg, Diagnostics* sink)
{
	if (arg == "-fapple-kext")
	{
		opts.apple_kext = true;
	}
	else if (arg == "-fcommon")
	{
		opts.common = true;
	}
	else if (arg == "-fno-common")
	{
		opts.common = false;
	}
	else if (arg == "-fintegrated-as")
	{
		opts.integrated_as = true;
		opts.has_integrated_as = true;
	}
	else if (arg == "-fno-integrated-as")
	{
		opts.integrated_as = false;
		opts.has_integrated_as = true;
	}
	else if (arg == "-fwhole-program")
	{
		opts.whole_program = true;
	}
	else if (arg == "-fno-whole-program")
	{
		opts.whole_program = false;
	}
	else if (arg == "-fshort-enums")
	{
		opts.short_enums = true; opts.has_short_enums = true;
	}
	else if (arg == "-fno-short-enums")
	{
		opts.short_enums = false; opts.has_short_enums = true;
	}
	else if (arg == "-fms-extensions")
	{
		opts.ms_extensions = true; opts.has_ms_extensions = true;
	}
	else if (arg == "-fno-ms-extensions")
	{
		opts.ms_extensions = false; opts.has_ms_extensions = true;
	}
	else if (arg == "-fdeclspec")
	{
		opts.declspec_attrs = true; opts.has_declspec_attrs = true;
	}
	else if (arg == "-fno-declspec")
	{
		opts.declspec_attrs = false; opts.has_declspec_attrs = true;
	}
	else if (arg == "-fdollars-in-identifiers")
	{
		opts.dollars_in_identifiers = true; opts.has_dollars_in_identifiers = true;
	}
	else if (arg == "-fno-dollars-in-identifiers")
	{
		opts.dollars_in_identifiers = false; opts.has_dollars_in_identifiers = true;
	}
	else if (arg == "-fdigraphs")
	{
		opts.digraphs = true; opts.has_digraphs = true;
	}
	else if (arg == "-fno-digraphs")
	{
		opts.digraphs = false; opts.has_digraphs = true;
	}
	else if (arg == "-fgnu-inline-asm")
	{
		opts.gnu_asm = true; opts.has_gnu_asm = true;
	}
	else if (arg == "-fno-gnu-inline-asm")
	{
		opts.gnu_asm = false; opts.has_gnu_asm = true;
	}
	else if (arg == "-fexperimental-bounds-safety")
	{
		opts.bounds_safety = CLANG; opts.has_bounds_safety = true;
	}
	else if (arg == "-fno-experimental-bounds-safety")
	{
		opts.bounds_safety = NONE; opts.has_bounds_safety = true;
	}
	else if (arg == "-fchar8_t")
	{
		opts.char8_t_override = ON; opts.has_char8_t_override = true;
	}
	else if (arg == "-fno-char8_t")
	{
		opts.char8_t_override = OFF; opts.has_char8_t_override = true;
	}
	else if (arg == "-fnative-half-type")
	{
		opts.use_native_half_type = true;
	}
	else if (arg == "-fnative-half-arguments-and-returns")
	{
		opts.allow_half_args_returns = true;
	}
	else if (arg == "-fblocks")
	{
		opts.has_blocks = true; opts.blocks = true;
	}
	else if (arg == "-fno-blocks")
	{
		opts.has_blocks = true; opts.blocks = false;
	}
	else if (arg == "-pthread")
	{
		opts.pthread = true;
	}
	else if (arg == "-fvisibility=default")
	{
		opts.visibility = DEFAULT; opts.has_visibility = true;
	}
	else if (arg == "-fvisibility=hidden")
	{
		opts.visibility = HIDDEN; opts.has_visibility = true;
	}
	else if (arg == "-fvisibility=protected")
	{
		opts.visibility = PROTECTED; opts.has_visibility = true;
	}
	else if (arg.starts_with("-fvisibility="))
	{
		String value = arg[13..];
		if (sink == null) return INVALID_ARGUMENT~;
		add_driver_fatal(opts.a, sink, "unsupported value '%s'' in '%s'", value, arg)!;
	}
	else
	{
		return false;
	}
	return true;
}

<* Parse one bounded group of options to keep driver argument parsing shallow. *>
fn bool? parse_frontend_flag_set_c(DriverOptions* opts, String arg, Diagnostics* sink)
{
	if (arg == "-fsigned-char" || arg == "-fno-unsigned-char")
	{
		opts.char_signedness = SIGNED; opts.has_char_signedness = true;
	}
	else if (arg == "-funsigned-char" || arg == "-fno-signed-char")
	{
		opts.char_signedness = UNSIGNED; opts.has_char_signedness = true;
	}
	else if (arg == "-ffreestanding")
	{
		opts.hosted = false; opts.has_hosted = true;
	}
	else if (arg == "-fhosted")
	{
		opts.hosted = true; opts.has_hosted = true;
	}
	else if (arg == "-fmacro-backtrace-limit=" || arg.starts_with("-fmacro-backtrace-limit="))
	{
		String value = arg[24..];
		uint limit;
		if (!parse_u32_decimal(value, &limit))
		{
			if (sink == null) return INVALID_ARGUMENT~;
			add_driver_error(opts.a, sink, "-fmacro-backtrace-limit takes a number argument")!;
		}
		else
		{
			opts.macro_backtrace_limit = limit == 0 ? uint::max : limit; opts.has_macro_backtrace_limit = true;
		}
	}
	else if (arg == "-fgnuc-version=" || arg.starts_with("-fgnuc-version="))
	{
		String value = arg == "-fgnuc-version=" ? "0" : arg[15..];
		gcc_version::GccVersion parsed_version = gcc_version::parse(value);
		if (parsed_version.major < 0)
		{
			if (sink == null) return INVALID_ARGUMENT~;
			add_driver_fatal(opts.a, sink, "invalid value '%s' in '-fgnuc-version=%s'", value, value)!;
		}
		else
		{
			opts.gnuc_version = value; opts.has_gnuc_version = true;
		}
	}
	else if (arg.starts_with("-ffp-eval-method="))
	{
		String value = arg[17..];
		if (value == "source")
		{
			opts.fp_eval_method = SOURCE; opts.has_fp_eval_method = true;
		}
		else if (value == "double")
		{
			opts.fp_eval_method = DOUBLE; opts.has_fp_eval_method = true;
		}
		else if (value == "extended")
		{
			opts.fp_eval_method = EXTENDED; opts.has_fp_eval_method = true;
		}
		else
		{
			if (sink == null) return INVALID_ARGUMENT~;
			add_driver_error(opts.a, sink, "unsupported argument '%s' to option '-ffp-eval-method='; expected 'source', 'double', or 'extended'", value)!;
		}
	}
	else if (arg.starts_with("--emulate="))
	{
		String value = arg[10..];
		if (value == "clang")
		{
			opts.emulate = CLANG;
		}
		else if (value == "gcc")
		{
			opts.emulate = GCC;
		}
		else if (value == "msvc")
		{
			opts.emulate = MSVC;
		}
		else
		{
			if (sink == null) return INVALID_ARGUMENT~;
			add_driver_error(opts.a, sink, "invalid compiler '%s'", arg)!;
		}
		if (value == "clang" || value == "gcc" || value == "msvc") opts.has_emulate = true;
	}
	else if (arg == "-fuse-ld=")
	{
		opts.has_use_linker = false; opts.use_linker = "";
	}
	else if (arg.starts_with("-fuse-ld="))
	{
		opts.has_use_linker = true; opts.use_linker = arg[9..];
	}
	else if (arg.starts_with("--ld-path="))
	{
		opts.has_linker_path = true; opts.linker_path = arg[10..];
	}
	else if (arg.starts_with("--rtlib="))
	{
		String value = arg[8..];
		if (value == "compiler-rt" || value == "libgcc" || value == "platform")
		{
			opts.has_rtlib = true; opts.rtlib = value;
		}
		else if (sink == null)
		{
			return INVALID_ARGUMENT~;
		}
		else
		{
			add_driver_error(opts.a, sink, "invalid runtime library name '%s'", value)!;
		}
	}
	else if (arg.starts_with("--unwindlib="))
	{
		String value = arg[12..];
		if (value == "" || value == "none" || value == "platform" || value == "libunwind" || value == "libgcc")
		{
			opts.has_unwindlib = true; opts.unwindlib = value;
		}
		else if (sink == null)
		{
			return INVALID_ARGUMENT~;
		}
		else
		{
			add_driver_error(opts.a, sink, "invalid unwind library name  '%s'", value)!;
		}
	}
	else if (arg.starts_with("-flto"))
	{
		String mode = arg[5..];
		if (mode.len == 0 || mode == "=auto" || mode == "=full" || mode == "=jobserver" || mode == "=thin")
		{
			if (sink != null) add_driver_warning(opts.a, sink, "lto not supported")!;
		}
		else if (sink == null)
		{
			return INVALID_ARGUMENT~;
		}
		else
		{
			add_driver_fatal(opts.a, sink, "invalid lto mode: '%s'", arg)!;
		}
	}
	else if (arg == "-fno-lto" || arg == "-frandom-seed=" || arg.starts_with("-frandom-seed="))
	{
		/* accepted, no effect */
	}
	else if (arg == "-mkernel")
	{
		opts.kernel = true;
	}
	else if (arg == "-fropi")
	{
		opts.ropi = true;
	}
	else if (arg == "-fno-ropi")
	{
		opts.ropi = false;
	}
	else if (arg == "-frwpi")
	{
		opts.rwpi = true;
	}
	else if (arg == "-fno-rwpi")
	{
		opts.rwpi = false;
	}
	else if (arg == "-g")
	{
		opts.debug_format = "dwarf32"; opts.has_debug_format = true;
	}
	else if (arg == "-g0")
	{
		opts.debug_format = "strip"; opts.has_debug_format = true;
	}
	else if (arg == "-gcodeview")
	{
		opts.debug_format = "codeview"; opts.has_debug_format = true;
	}
	else if (arg == "-gdwarf32")
	{
		opts.debug_format = "dwarf32"; opts.has_debug_format = true;
	}
	else if (arg == "-gdwarf64")
	{
		opts.debug_format = "dwarf64"; opts.has_debug_format = true;
	}
	else if (arg == "-gdwarf" || arg == "-gdwarf-2" || arg == "-gdwarf-3" || arg == "-gdwarf-4" || arg == "-gdwarf-5")
	{
		opts.debug_format = "dwarf32"; opts.has_debug_format = true;
		if (arg == "-gdwarf-2")
		{
			opts.dwarf_version = 2; opts.has_dwarf_version = true;
		}
		else if (arg == "-gdwarf-3")
		{
			opts.dwarf_version = 3; opts.has_dwarf_version = true;
		}
		else if (arg == "-gdwarf-4")
		{
			opts.dwarf_version = 4; opts.has_dwarf_version = true;
		}
		else if (arg == "-gdwarf-5")
		{
			opts.dwarf_version = 5; opts.has_dwarf_version = true;
		}
	}
	else if (arg == "-nobuiltininc")
	{
		opts.nobuiltininc = true;
	}
	else if (arg == "-nostdinc" || arg == "--no-standard-includes")
	{
		opts.nostdinc = true;
	}
	else if (arg == "-nostdlibinc")
	{
		opts.nostdlibinc = true;
	}
	else if (arg == "-nostdlib")
	{
		opts.no_standard_libraries = true; opts.nostdlib = true;
	}
	else if (arg == "-nodefaultlibs")
	{
		opts.no_standard_libraries = true; opts.nodefaultlibs = true;
	}
	else if (arg == "-nolibc")
	{
		opts.no_standard_libraries = true; opts.nolibc = true;
	}
	else if (arg == "-nostartfiles")
	{
		opts.no_standard_libraries = true; opts.nostartfiles = true;
	}
	else if (arg == "-shared")
	{
		opts.shared = true;
	}
	else if (arg == "-shared-libgcc")
	{
		opts.shared_libgcc = true;
	}
	else if (arg == "-static-libgcc")
	{
		opts.static_libgcc = true;
	}
	else if (arg == "-static-pie")
	{
		opts.static_pie = true;
	}
	else if (arg == "-static")
	{
		opts.static_link = true;
	}
	else if (arg == "-pie")
	{
		opts.has_pie = true; opts.pie = true;
	}
	else if (arg == "-no-pie" || arg == "-nopie")
	{
		opts.has_pie = true; opts.pie = false;
	}
	else if (arg == "-r")
	{
		opts.relocatable = true;
	}
	else if (arg == "-rdynamic")
	{
		opts.rdynamic = true;
	}
	else if (arg == "-s")
	{
		opts.strip = true;
	}
	else if (arg == "-Werror")
	{
		opts.warnings_as_errors = true;
	}
	else if (arg == "-w")
	{
		opts.ignore_warnings = true;
	}
	else if (arg == "-mdynamic-no-pic")
	{
		opts.dynamic_nopic = true;
	}
	else if (arg == "-mabicalls")
	{
		opts.has_mabicalls = true; opts.mabicalls = true;
	}
	else if (arg == "-mno-abicalls")
	{
		opts.has_mabicalls = true; opts.mabicalls = false;
	}
	else if (arg == "-fpic")
	{
		opts.pic = PIC; opts.pic_arg = arg;
	}
	else if (arg == "-fPIC")
	{
		opts.pic = PIC_LARGE; opts.pic_arg = arg;
	}
	else if (arg == "-fpie")
	{
		opts.pic = PIE; opts.pic_arg = arg;
	}
	else if (arg == "-fPIE")
	{
		opts.pic = PIE_LARGE; opts.pic_arg = arg;
	}
	else if (arg == "-fno-pic" || arg == "-fno-PIC" || arg == "-fno-pie" || arg == "-fno-PIE")
	{
		opts.pic = NO_PIC; opts.pic_arg = arg;
	}
	else
	{
		return false;
	}
	return true;
}

<* Dispatch frontend and code-generation options to bounded option groups. *>
fn bool? parse_frontend_flag(DriverOptions* opts, String arg, Diagnostics* sink)
{
	if (parse_frontend_flag_set_a(opts, arg, sink)!) return true;
	if (parse_frontend_flag_set_b(opts, arg, sink)!) return true;
	if (parse_frontend_flag_set_c(opts, arg, sink)!) return true;
	return false;
}

<* Parse linker search-path and library options without adding branches to the
 main argument parser. *>
fn bool? parse_link_flag(DriverOptions* opts, String[] args, usz* i)
{
	String arg = args[*i];
	if (arg.starts_with("-L"))
	{
		String path = arg[2..];
		if (path.len == 0)
		{
			(*i)++;
			if (*i >= args.len) return MISSING_ARGUMENT~;
			path = args[*i];
		}
		opts.lib_dirs.push(path);
		return true;
	}
	if (arg == "-l" || (arg.starts_with("-l") && arg.len > 2))
	{
		if (arg.len == 2)
		{
			(*i)++;
			if (*i >= args.len) return MISSING_ARGUMENT~;
			String owned = string::format(opts.a, "-l%s", args[*i]);
			opts.owned_link_args.push(owned);
			opts.link_objects.push(owned);
		}
		else
		{
			opts.link_objects.push(arg);
		}
		return true;
	}
	return false;
}

fn void push_source_input(DriverOptions* opts, String arg)
{
	opts.inputs.push(arg);
	opts.input_link_slots.push((usz)opts.link_objects.len());
}

fn bool is_link_input_path(String arg)
{
	if (arg.ends_with(".o") || arg.ends_with(".obj") || arg.ends_with(".a") || arg.ends_with(".so")) return true;
	String basename = arg;
	if (try slash = arg.rindex_of_char('/')) basename = arg[slash + 1..];
	if (try version_at = basename.index_of(".so."))
	{
		String version = basename[version_at + 4..];
		if (version.len == 0) return false;
		bool component_has_digit = false;
		foreach (c : version)
		{
			if (c >= '0' && c <= '9')
			{
				component_has_digit = true;
			}
			else if (c == '.' && component_has_digit)
			{
				component_has_digit = false;
			}
			else
			{
				return false;
			}
		}
		return component_has_digit;
	}
	return false;
}

<* Parse arguments (including argv[0]) into caller-owned reusable state.
 Recognized source paths and option values are borrowed from args. Unknown
 options are retained as diagnostics-free parse failures instead of silently
 invoking a backend. A leading '-' remains a source/stdin style input unless
 it begins a recognized option. *>
fn ArgumentResult? parse_args(DriverOptions* opts, String[] args, Diagnostics* sink = null)
{
	ArgumentResult result = { .action = CONTINUE };
	if (args.len == 0) return result;
	usz i = 1;
	while (i < args.len)
	{
		String arg = args[i];
		if (arg == "--help" || arg == "-h")
		{
			opts.action = HELP; result.action = HELP; result.input_count = (uint)opts.inputs.len(); return result;
		}
		if (arg == "--version")
		{
			opts.action = VERSION; result.action = VERSION; result.input_count = (uint)opts.inputs.len(); return result;
		}
		if (parse_frontend_flag(opts, arg, sink)!)
		{
			i++; continue;
		}
		if (parse_link_flag(opts, args, &i)!)
		{
			i++; continue;
		}
		else if (arg.starts_with("-D"))
		{
			String v = arg[2..]; if (v.len == 0)
			{
				i++; if (i >= args.len) return MISSING_ARGUMENT~; v = args[i];
			}
			opts.defines.push(v); opts.macro_effects.push(
			{
				.kind = DEFINE, .value = v
			}
			);
		}
		else if (arg.starts_with("-U"))
		{
			String v = arg[2..]; if (v.len == 0)
			{
				i++; if (i >= args.len) return MISSING_ARGUMENT~; v = args[i];
			}
			opts.undefs.push(v); opts.macro_effects.push(
			{
				.kind = UNDEFINE, .value = v
			}
			);
		}
		else if (arg.starts_with("-I"))
		{
			String v = arg[2..]; if (v.len == 0)
			{
				i++; if (i >= args.len) return MISSING_ARGUMENT~; v = args[i];
			}
			opts.includes.push(
			{
				.kind = NORMAL, .path = v
			}
			);
		}
		else if (arg == "--embed-dir")
		{
			i++; if (i >= args.len) return MISSING_ARGUMENT~; opts.embed_dirs.push(args[i]);
		}
		else if (arg == "-iquote" || arg == "-isystem" || arg == "-idirafter" || arg == "-F" || arg == "-iframework")
		{
			i++; if (i >= args.len) return MISSING_ARGUMENT~;
			IncludeKind kind = arg == "-iquote" ? QUOTE : arg == "-isystem" ? SYSTEM : arg == "-idirafter" ? AFTER : arg == "-F" ? FRAMEWORK : SYSTEM_FRAMEWORK;
			opts.includes.push(
			{
				.kind = kind, .path = args[i]
			}
			);
		}
		else if (arg == "-o" || arg == "--sysroot" || arg == "-isysroot" || arg == "-resource-dir" || arg == "-mcpu" || arg == "-target" || arg == "--target" || arg == "-std" || arg == "-MF" || arg == "-darwin-target-variant-triple" || arg == "-rpath")
		{
			i++; if (i >= args.len) return MISSING_ARGUMENT~;
			String v = args[i];
			if (arg == "-o")
			{
				opts.output_name = v; opts.has_output_name = true;
			}
			else if (arg == "--sysroot" || arg == "-isysroot")
			{
				opts.sysroot = v; opts.has_sysroot = true;
			}
			else if (arg == "-resource-dir")
			{
				opts.resource_dir = v; opts.has_resource_dir = true;
			}
			else if (arg == "-mcpu")
			{
				opts.cpu = v; opts.has_cpu = true;
			}
			else if (arg == "-target" || arg == "--target")
			{
				opts.target_triple = v; opts.has_target_triple = true; opts.has_emulate = false;
			}
			else if (arg == "-std")
			{
				opts.standard = v; opts.has_standard = true;
			}
			else if (arg == "-MF")
			{
				opts.dependency_file = v; opts.has_dependency_file = true;
			}
			else if (arg == "-darwin-target-variant-triple")
			{
				opts.darwin_variant_triple = v; opts.has_darwin_variant_triple = true;
			}
		}
		else if (arg.starts_with("--target="))
		{
			opts.target_triple = arg[9..]; opts.has_target_triple = true; opts.has_emulate = false;
		}
		else if (arg.starts_with("--embed-dir="))
		{
			opts.embed_dirs.push(arg[12..]);
		}
		else if (arg.starts_with("--sysroot="))
		{
			opts.sysroot = arg[10..]; opts.has_sysroot = true;
		}
		else if (arg.starts_with("--resource-dir="))
		{
			opts.resource_dir = arg[15..]; opts.has_resource_dir = true;
		}
		else if (arg.starts_with("-resource-dir="))
		{
			opts.resource_dir = arg[14..]; opts.has_resource_dir = true;
		}
		else if (arg.starts_with("-isysroot"))
		{
			opts.sysroot = arg[9..]; opts.has_sysroot = true;
		}
		else if (arg == "-Wp,-v")
		{
			/* accepted; verbose search paths are not implemented */
		}
		else if (arg == "-Wno-error" || arg == "-Werror" || arg == "-Wfatal-errors" || arg == "-Wno-fatal-errors" || arg == "-Weverything" || arg == "-Wno-everything" || arg == "-Wsystem-headers" || arg == "-Wno-system-headers" || arg == "-pedantic" || arg == "-pedantic-errors" || arg == "-fcaret-diagnostics" || arg == "-fno-caret-diagnostics" || arg == "-fcolor-diagnostics" || arg == "-fno-color-diagnostics")
		{
			/* applied by diagnostics setup */
		}
		else if (arg.starts_with("-mcpu="))
		{
			opts.cpu = arg[6..]; opts.has_cpu = true;
		}
		else if (arg.starts_with("-std="))
		{
			opts.standard = arg[5..]; opts.has_standard = true;
		}
		else if (arg.starts_with("--sysroot="))
		{
			opts.sysroot = arg[10..]; opts.has_sysroot = true;
		}
		else if (arg.starts_with("-O"))
		{
			String level = arg[2..]; if (level.len == 0) level = "1"; if (level != "0" && level != "1" && level != "2" && level != "3" && level != "s" && level != "z" && level != "g" && level != "fast") return INVALID_ARGUMENT~; opts.optimization = level; opts.has_optimization = true;
		}
		else if (arg == "-M" || arg == "--dependencies")
		{
			opts.dependency_only = true; opts.ignore_warnings = true; opts.only_preprocess = true;
		}
		else if (arg == "-MD" || arg == "--write-dependencies")
		{
			opts.write_dependencies = true;
		}
		else if (arg == "-MV")
		{
			opts.dependency_nmake = true;
		}
		else if (arg.starts_with("-MF"))
		{
			String v = arg[3..]; if (v.len == 0)
			{
				i++; if (i >= args.len) return MISSING_ARGUMENT~; v = args[i];
			}
			opts.dependency_file = v; opts.has_dependency_file = true;
		}
		else if (arg.starts_with("-mcmodel="))
		{
			String model_name = arg[9..];
			bool valid = false;
			foreach (model : code_gen_options::CodeModel::values) if (model.name == model_name)
			{
				valid = true; break;
			}
			if (!valid) return INVALID_ARGUMENT~;
			opts.code_model = model_name; opts.has_code_model = true;
		}
		else if (arg.starts_with("-W"))
		{
			parse_warning_option(opts, arg);
		}
		else if (arg == "-")
		{
			push_source_input(opts, arg);
		}
		else if (arg.starts_with("-f") || arg.starts_with("-m"))
		{
			if (sink == null) return INVALID_ARGUMENT~;
			add_driver_warning(opts.a, sink, "unknown argument '%s'", arg)!;
		}
		else if (arg.starts_with("-"))
		{
			if (sink == null) return INVALID_ARGUMENT~;
			add_driver_warning(opts.a, sink, "unknown argument '%s'", arg)!;
		}
		else if (is_link_input_path(arg))
		{
			opts.link_objects.push(arg);
		}
		else
		{
			push_source_input(opts, arg);
		}
		i++;
	}
	result.input_count = (uint)opts.inputs.len();
	return result;
}

<* Resolve a triple with the same target parser used by compilation. *>
fn Target? parse_target(DriverOptions* opts)
{
	Host h = target::host()!;
	String triple = opts.has_target_triple ? opts.target_triple : "native";
	String cpu = opts.has_cpu ? opts.cpu : "";
	return target::parse_triple(triple, h, cpu);
}

<* Apply parsed state after parsing, without opening inputs or invoking a backend.
 Macro effects remain in argv order for the caller to replay into its preprocessor. *>
fn ParseEffect[]? apply_options(DriverOptions* opts, Compilation* comp, toolchain::Options* tc_opts, Diagnostics* sink = null)
{
	if (opts.has_target_triple)
	{
		Target t = parse_target(opts)!;
		comp.target = t;
	}
	if (opts.has_darwin_variant_triple)
	{
		Host h = target::host()!;
		comp.darwin_target_variant = target::parse_triple(opts.darwin_variant_triple, h)!;
		comp.has_darwin_target_variant = true;
	}
	// Match src/aro/Driver.zig:855 after resolving the target and Darwin variant.
	comp.langopts.set_target_options(&comp.target);
	if (opts.has_standard) comp.langopts.set_standard(opts.standard)!;
	if (opts.has_emulate || opts.has_target_triple)
	{
		lang_opts::Compiler compiler = opts.has_emulate ? opts.emulate : comp.target.system_compiler();
		comp.langopts.set_emulated_compiler(compiler);
		if (sink != null)
		{
			if (compiler == CLANG)
			{
				sink.set("clang", diagnostics::MessageKind.OFF)!;
			}
			else if (compiler == GCC)
			{
				sink.set("gnu", diagnostics::MessageKind.OFF)!;
			}
			else if (compiler == MSVC)
			{
				sink.set("microsoft", diagnostics::MessageKind.OFF)!;
			}
		}
	}
	comp.langopts.preserve_comments = opts.preserve_comments;
	comp.langopts.preserve_comments_in_macros = opts.preserve_comments_in_macros;
	if (opts.has_short_enums) comp.langopts.short_enums = opts.short_enums;
	if (opts.has_dollars_in_identifiers) comp.langopts.dollars_in_identifiers = opts.dollars_in_identifiers;
	if (opts.has_digraphs) comp.langopts.digraphs = opts.digraphs ? ON : OFF;
	if (opts.has_gnu_asm) comp.langopts.gnu_asm = opts.gnu_asm;
	if (opts.has_bounds_safety) comp.langopts.bounds_safety = opts.bounds_safety;
	if (opts.has_char8_t_override) comp.langopts.has_char8_t_override = opts.char8_t_override;
	if (opts.has_visibility) comp.langopts.default_symbol_visibility = opts.visibility;
	comp.langopts.use_native_half_type = opts.use_native_half_type;
	comp.langopts.allow_half_args_and_returns = opts.allow_half_args_returns;
	if (opts.has_blocks) comp.langopts.blocks = opts.blocks;
	if ((comp.langopts.emulate == CLANG || comp.langopts.emulate == NO) && comp.target.os.tag.is_darwin())
	{
		comp.langopts.blocks = comp.langopts.blocks || comp.target.is_blocks_supported();
	}
	comp.langopts.pthread = opts.pthread;
	if (opts.has_char_signedness) comp.langopts.set_char_signedness(opts.char_signedness);
	if (opts.has_fp_eval_method) comp.langopts.set_fp_eval_method(opts.fp_eval_method);
	if (opts.has_declspec_attrs) comp.langopts.declspec_attrs = opts.declspec_attrs;
	if (opts.has_ms_extensions) comp.langopts.set_ms_extensions(opts.ms_extensions);
	if (opts.has_hosted)
	{
		if (opts.hosted && comp.target.os.tag == target::OsTag.FREESTANDING)
		{
			if (sink == null) return INVALID_ARGUMENT~;
			add_driver_fatal(comp.gpa, sink, "Cannot use freestanding target with `-fhosted`")!;
			return INVALID_ARGUMENT~;
		}
		if (!opts.hosted) comp.target.os.tag = target::OsTag.FREESTANDING;
	}
	if (opts.has_gnuc_version)
	{
		gcc_version::GccVersion version = gcc_version::parse(opts.gnuc_version);
		if (version.major < 0) return INVALID_ARGUMENT~;
		comp.langopts.has_gnuc_version = true;
		comp.langopts.gnuc_version = version.to_unsigned();
	}
	if (opts.has_macro_backtrace_limit && sink != null) sink.macro_backtrace_limit = opts.macro_backtrace_limit;
	if (comp.include_dirs.ptr) alloc::free(comp.gpa, comp.include_dirs.ptr);
	comp.include_dirs = alloc::clone_slice(comp.gpa, opts.includes.array_view());
	comp.code_gen_options.common = opts.common;
	comp.code_gen_options.is_ropi = opts.ropi;
	comp.code_gen_options.is_rwpi = opts.rwpi;
	if (opts.has_optimization) comp.code_gen_options.optimization_level = code_gen_options::optimization_level_from_string(opts.optimization)!;
	if (opts.has_code_model)
	{
		bool found = false;
		foreach (model : code_gen_options::CodeModel::values) if (model.name == opts.code_model)
		{
			comp.cmodel = model; found = true; break;
		}
		if (!found) return INVALID_ARGUMENT~;
	}
	if (opts.has_debug_format)
	{
		if (opts.debug_format == "strip")
		{
			comp.code_gen_options.debug = { .kind = STRIP };
		}
		else if (opts.debug_format == "codeview")
		{
			comp.code_gen_options.debug = { .kind = CODE_VIEW };
		}
		else
		{
			comp.code_gen_options.debug = { .kind = DWARF, .dwarf = opts.debug_format == "dwarf64" ? FORMAT64 : FORMAT32 };
		}
	}
	if (opts.has_dwarf_version) comp.code_gen_options.dwarf_version = (DwarfVersion)opts.dwarf_version;
	PicPolicy pic = pic_policy(opts, comp.target, sink)!;
	comp.code_gen_options.pic_level = pic.level;
	comp.code_gen_options.is_pie = pic.is_pie;
	tc_opts.has_sysroot = opts.has_sysroot; tc_opts.sysroot = opts.sysroot;
	tc_opts.user_lib_dirs = opts.lib_dirs.array_view();
	tc_opts.has_resource_dir = opts.has_resource_dir; tc_opts.resource_dir = opts.resource_dir;
	tc_opts.nobuiltininc = opts.nobuiltininc; tc_opts.nostdinc = opts.nostdinc; tc_opts.nostdlibinc = opts.nostdlibinc;
	tc_opts.nostdlib = opts.nostdlib; tc_opts.nodefaultlibs = opts.nodefaultlibs;
	tc_opts.nolibc = opts.nolibc; tc_opts.nostartfiles = opts.nostartfiles;
	tc_opts.shared = opts.shared; tc_opts.is_static = opts.static_link;
	tc_opts.has_pie = opts.has_pie; tc_opts.pie = opts.pie; tc_opts.relocatable = opts.relocatable;
	tc_opts.rdynamic = opts.rdynamic; tc_opts.shared_libgcc = opts.shared_libgcc;
	tc_opts.static_libgcc = opts.static_libgcc; tc_opts.static_pie = opts.static_pie; tc_opts.strip = opts.strip;
	tc_opts.has_use_linker = opts.has_use_linker; tc_opts.use_linker = opts.use_linker;
	tc_opts.has_linker_path = opts.has_linker_path; tc_opts.linker_path = opts.linker_path;
	tc_opts.has_rtlib = opts.has_rtlib; tc_opts.rtlib = opts.rtlib;
	tc_opts.has_unwindlib = opts.has_unwindlib; tc_opts.unwindlib = opts.unwindlib;
	tc_opts.has_raw_target_triple = opts.has_target_triple; tc_opts.raw_target_triple = opts.target_triple;
	return opts.macro_effects.array_view();
}

<* Calculate target defaults and apply the last explicit -fpic family option. *>
fn bool string_ieq(String a, String b)
{
	if (a.len != b.len) return false;
	foreach (i, c : a) if (c.to_lower() != b[i].to_lower()) return false;
	return true;
}

fn void? unsupported_target_option(DriverOptions* opts, Target t, Diagnostics* sink, String option)
{
	if (sink == null) return;
	return add_driver_error(opts.a, sink, "unsupported option '%s' for target '%s-%s-%s'",
		option, t.cpu.arch.name, t.os.tag.name, t.abi.name);
}

fn PicPolicy? pic_policy(DriverOptions* opts, Target t, Diagnostics* sink = null)
{
	String linker = opts.has_use_linker ? opts.use_linker : system_defaults::LINKER;
	bool bfd = string_ieq(linker, "bfd");
	bool pie_default = t.is_pie_default() == YES ||
	(t.is_pie_default() == DEPENDS_ON_LINKER && bfd && t.cpu.arch == X86_64);
	bool pic_default = t.is_pic_default() == YES ||
	(t.is_pic_default() == DEPENDS_ON_LINKER && (bfd
		? t.cpu.arch == X86_64
		: t.cpu.arch == X86_64 || t.cpu.arch == AARCH64));
	bool forced = t.is_pic_default_forced() == YES ||
	(t.is_pic_default_forced() == DEPENDS_ON_LINKER && (bfd
		? t.cpu.arch == X86_64
		: t.cpu.arch == X86_64 || t.cpu.arch == AARCH64));
	bool pie = pie_default;
	bool pic = pie || pic_default;
	if (opts.static_link && t.ofmt == MACHO)
	{
		pic = false; pie = false;
	}
	bool level_two = pic;

	if (t.abi.is_android())
	{
		switch (t.cpu.arch)
		{
			case ARM:
			case ARMEB:
			case THUMB:
			case THUMBEB:
			case AARCH64:
			case MIPS:
			case MIPSEL:
			case MIPS64:
			case MIPS64EL: pic = true;
			case X86:
			case X86_64: pic = true; level_two = true;
			default: break;
		}
	}
	if (t.abi == OHOS && t.cpu.arch == AARCH64) pic = true;
	if (t.os.tag == OPENBSD)
	{
		switch (t.cpu.arch)
		{
			case ARM:
			case AARCH64:
			case MIPS64:
			case MIPS64EL:
			case X86:
			case X86_64: level_two = false;
			case POWERPC:
			case SPARC64: level_two = true;
			default: break;
		}
	}

	String pic_arg = opts.pic_arg;
	bool positive_pic_option = string_ieq(pic_arg, "-fpic") || string_ieq(pic_arg, "-fpie");
	if (t.os.tag == WINDOWS && !t.is_mingw() && positive_pic_option)
	{
		if (sink != null) unsupported_target_option(opts, t, sink, pic_arg)!;
		if (t.cpu.arch == X86_64) return { .level = TWO, .is_pie = false };
		return { .level = NONE, .is_pie = false };
	}

	if (!forced)
	{
		switch (opts.pic)
		{
			case DEFAULT: break;
			case NO_PIC: pic = false; pie = false;
			case PIC: pic = true; pie = false; level_two = false;
			case PIC_LARGE: pic = true; pie = false; level_two = true;
			case PIE: pic = true; pie = true; level_two = false;
			case PIE_LARGE: pic = true; pie = true; level_two = true;
		}
	}

	bool kernel_code_model = opts.has_code_model && opts.code_model == "kernel";
	if (pic && (t.os.tag.is_darwin() || t.is_ps())) level_two = level_two || pic_default;
	if (t.is_ps() && !kernel_code_model)
	{
		if (!pic)
		{
			pic = true;
			if (sink != null) add_driver_warning(opts.a, sink,
				"option '%s' was ignored by the %s toolchain, using '-fPIC'",
				pic_arg, t.os.tag == PS4 ? "PS4" : "PS5")!;
		}
		if (pic) level_two = level_two || pic_default;
	}

	bool kernel_abi_os = t.os.tag == WATCHOS || t.os.tag == DRIVERKIT
	|| (t.os.tag == IOS && t.os.is_at_least_or_false(IOS, { 6, 0, 0 }))
	|| (t.os.tag == MACCATALYST && t.os.is_at_least_or_false(MACCATALYST, { 6, 0, 0 }));
	if ((opts.kernel || opts.apple_kext) && kernel_abi_os)
	{
		pic = false; pie = false;
	}
	if ((opts.kernel || opts.apple_kext) && t.os.tag == IOS && !t.os.is_at_least_or_false(IOS, { 6, 0, 0 })) level_two = false;

	if (opts.dynamic_nopic)
	{
		if (!t.os.tag.is_darwin() && sink != null) unsupported_target_option(opts, t, sink, "-mdynamic-no-pic")!;
		pic = pic_default || forced;
		return { .level = pic ? TWO : NONE, .is_pie = false };
	}

	if (!t.cpu.arch.is_arm())
	{
		if (sink != null && opts.ropi) unsupported_target_option(opts, t, sink, "-fropi")!;
		if (sink != null && opts.rwpi) unsupported_target_option(opts, t, sink, "-frwpi")!;
	}
	if ((opts.ropi || opts.rwpi) && (pic || pie))
	{
		if (sink == null) return { .level = pic ? (level_two ? TWO : ONE) : NONE, .is_pie = pie };
		add_driver_error(opts.a, sink, "embedded and GOT-based position independence are incompatible")!;
	}

	if (t.cpu.arch.is_mips())
	{
		if (t.cpu.arch.is_mips64()) pic = true;
		level_two = false;
		if (opts.has_mabicalls && !opts.mabicalls) return { .level = NONE, .is_pie = false };
	}
	if (!pic) return { .level = NONE, .is_pie = false };
	return { .level = level_two ? TWO : ONE, .is_pie = pie };
}

// ---------------------------------------------------------------------------
// Production front-end lifecycle

struct FrontendOptions
{
	List{String} implicit_includes;
	List{String} imacros;
	bool dump_m;
	bool dump_d;
	bool dump_n;
	bool has_ms_extensions;
	bool ms_extensions;
	bool has_color;
	bool color;
}

fn void FrontendOptions.init(&self, Allocator a)
{
	self.implicit_includes.init(a);
	self.imacros.init(a);
}

fn void FrontendOptions.free(&self)
{
	self.implicit_includes.free();
	self.imacros.free();
	*self = {};
}

fn preprocessor::DumpMode FrontendOptions.dump_mode(&self)
{
	if (self.dump_m) return preprocessor::DumpMode.MACROS_ONLY;
	if (self.dump_d) return preprocessor::DumpMode.MACROS_AND_RESULT;
	if (self.dump_n) return preprocessor::DumpMode.MACRO_NAMES_AND_RESULT;
	return preprocessor::DumpMode.RESULT_ONLY;
}

fn void? add_driver_error(Allocator a, Diagnostics* d, String fmt, args...) @format(2)
{
	@pool()
	{
		return d.add(
		{
			.kind = ERROR, .text = string::tformat(fmt, ...args)
		}
		);
	};
}

fn void? add_driver_fatal(Allocator a, Diagnostics* d, String fmt, args...) @format(2)
{
	@pool()
	{
		return d.add(
		{
			.kind = FATAL_ERROR, .text = string::tformat(fmt, ...args)
		}
		);
	};
}

fn void? add_driver_warning(Allocator a, Diagnostics* d, String fmt, args...) @format(2)
{
	@pool()
	{
		return d.add(
		{
			.kind = WARNING, .text = string::tformat(fmt, ...args)
		}
		);
	};
}

<* Split driver-only switches from the shared option parser. *>
fn void? filter_frontend_args(String[] args, List{String} * filtered, FrontendOptions* extra)
{
	if (args.len == 0) return INVALID_ARGUMENT~;
	filtered.push(args[0]);
	usz i = 1;
	while (i < args.len)
	{
		String arg = args[i];
		if (arg == "-include" || arg == "-imacros")
		{
			i++;
			if (i >= args.len) return MISSING_ARGUMENT~;
			if (arg == "-include")
			{
				extra.implicit_includes.push(args[i]);
			}
			else
			{
				extra.imacros.push(args[i]);
			}
		}
		else if (arg == "-dM")
		{
			extra.dump_m = true;
		}
		else if (arg == "-dD")
		{
			extra.dump_d = true;
		}
		else if (arg == "-dN")
		{
			extra.dump_n = true;
		}
		else if (arg == "-fcolor-diagnostics")
		{
			extra.has_color = true; extra.color = true;
		}
		else if (arg == "-fno-color-diagnostics")
		{
			extra.has_color = true; extra.color = false;
		}
		else if (arg == "-fms-extensions")
		{
			extra.has_ms_extensions = true; extra.ms_extensions = true; filtered.push(arg);
		}
		else if (arg == "-fno-ms-extensions")
		{
			extra.has_ms_extensions = true; extra.ms_extensions = false; filtered.push(arg);
		}
		else
		{
			filtered.push(arg);
		}
		i++;
	}
	return;
}

<* Apply the warning switches accepted by the shared parser. *>
fn void? apply_diagnostic_options(String[] args, Diagnostics* d)
{
	foreach (arg : args[1..])
	{
		if (arg == "-Werror")
		{
			d.state.error_warnings = true;
		}
		else if (arg == "-Wno-error")
		{
			d.state.error_warnings = false;
		}
		else if (arg == "-w")
		{
			d.state.ignore_warnings = true;
		}
		else if (arg == "-Weverything")
		{
			d.state.enable_all_warnings = true;
		}
		else if (arg == "-Wno-everything")
		{
			d.state.enable_all_warnings = false;
		}
		else if (arg == "-Wfatal-errors")
		{
			d.state.fatal_errors = true;
		}
		else if (arg == "-Wno-fatal-errors")
		{
			d.state.fatal_errors = false;
		}
		else if (arg == "-fcaret-diagnostics")
		{
			d.details = true;
		}
		else if (arg == "-fno-caret-diagnostics")
		{
			d.details = false;
		}
		else if (arg == "-Wsystem-headers")
		{
			d.state.suppress_system_headers = false;
		}
		else if (arg == "-Wno-system-headers")
		{
			d.state.suppress_system_headers = true;
		}
		else if (arg == "-pedantic")
		{
			d.state.extensions = diagnostics::MessageKind.WARNING;
		}
		else if (arg == "-pedantic-errors")
		{
			d.state.extensions = diagnostics::MessageKind.ERROR;
		}
		else if (arg.starts_with("-Werror="))
		{
			d.set(arg[8..], diagnostics::MessageKind.ERROR)!;
		}
		else if (arg.starts_with("-Wno-error="))
		{
			d.set(arg[11..], diagnostics::MessageKind.WARNING)!;
		}
		else if (arg.starts_with("-Wno-"))
		{
			d.set(arg[5..], diagnostics::MessageKind.OFF)!;
		}
		else if (arg.starts_with("-W"))
		{
			d.set(arg[2..], diagnostics::MessageKind.WARNING)!;
		}
	}
	return;
}

<* Host filesystem callbacks used by normal CLI invocations. Tests may
 preinstall Compilation.include_files to use deterministic fake services. *>
fn bool host_include_exists(void* ctx, String path) => file::is_file(path);

fn char[]? host_include_read(void* ctx, Allocator a, String path, ulong limit)
{
	char[]? data = file::load(a, path);
	if (catch data) return preprocessor::FILE_NOT_FOUND~;
	if (limit != ulong::max && (ulong)data.len > limit) data = data[:(usz)limit];
	return data;
}

fn ulong? host_include_mtime(void* ctx, String path) => (ulong)(os::native_get_modified_time(path) ?? 0);

fn void install_default_file_services(Compilation* comp)
{
	if (!comp.include_files.exists || !comp.include_files.read)
	{
		comp.include_files = { .exists = &host_include_exists, .read = &host_include_read, .mtime = &host_include_mtime };
	}
}

fn void install_default_pragmas(Compilation* comp)
{
	pragma::IPragma? gcc_handler = comp.pragmas.get("GCC");
	if (catch gcc_handler) comp.pragmas.add("GCC", gcc::make_handler(comp.gpa));
	pragma::IPragma? once_handler = comp.pragmas.get("once");
	if (catch once_handler) comp.pragmas.add("once", once::handler(comp.gpa));
	pragma::IPragma? message_handler = comp.pragmas.get("message");
	if (catch message_handler) comp.pragmas.add("message", message::handler());
	pragma::IPragma? pack_handler = comp.pragmas.get("pack");
	if (catch pack_handler) comp.pragmas.add("pack", pack::make_handler(comp.gpa));
}

fn char[]? read_stdin(Allocator a, File* input)
{
	List{char} bytes;
	bytes.init(a);
	defer bytes.free();
	char[8192] buffer;
	while (true)
	{
		sz? count = input.read(buffer[..]);
		if (catch f = count)
		{
			if (f == io::EOF) break;
			return f~;
		}
		if (count == 0) break;
		bytes.push_all(buffer[:count]);
	}
	char* out = alloc::malloc(a, (sz)bytes.len() + 1);
	if (bytes.len()) mem::copy(out, bytes.array_view().ptr, bytes.len());
	out[bytes.len()] = 0;
	return out[:bytes.len()];
}

fn String file_stem(String path)
{
	path::Path parsed = path::tnew(path)!!;
	String basename = parsed.basename();
	String? extension_opt = parsed.extension();
	if (catch extension_opt) return basename;
	String extension = extension_opt;
	if (extension.len == 0) return basename;
	return basename[:basename.len - extension.len - 1];
}

fn Source? make_command_line_source(Compilation* comp, DriverOptions* opts)
{
	DString macro_text;
	macro_text.init(comp.gpa);
	defer macro_text.free();
	foreach (effect : opts.macro_effects)
	{
		if (effect.kind == UNDEFINE)
		{
			macro_text.appendf("#undef %s\n", effect.value)!!;
		}
		else
		{
			String name = effect.value;
			String value = "1";
			if (try split = name.index_of_char('='))
			{
				value = name[split + 1..];
				name = name[:split];
			}
			macro_text.appendf("#define %s %s\n", name, value)!!;
		}
	}
	return comp.add_source_from_buffer("<command line>", macro_text.str_view());
}

fn Source? load_cli_include(Compilation* comp, String path)
{
	Source? source_opt = comp.search_include(path, source::GENERATED_ID, preprocessor::IncludeType.CLI, preprocessor::WhichInclude.FIRST, null);
	if (catch f = source_opt)
	{
		if (f == preprocessor::FILE_NOT_FOUND) return CLI_INCLUDE_NOT_FOUND~;
		return f~;
	}
	return source_opt;
}

fn String toolchain_fault_message(fault f)
{
	if (f == toolchain::RESOURCE_DIR_NOT_FOUND) return "builtin headers not found in requested resource directory";
	if (f == toolchain::BUILTIN_HEADERS_NOT_FOUND) return "unable to find Aro builtin headers; set RUNFILES_DIR or -resource-dir";
	if (f == INVALID_TARGET) return "invalid target";
	if (f == multilib::TOO_MANY_MULTILIBS) return "found more than one multilib with the same priority";
	return string::tformat("unable to configure toolchain: %s", f);
}

fn bool? configure_toolchain(Compilation* comp, DriverOptions* opts,
	toolchain::Options* tc_opts, toolchain::Toolchain* tc, List{IncludeDir} * all_includes,
	List{String} * owned_include_paths, Diagnostics* sink)
{
	ParseEffect[] effects = apply_options(opts, comp, tc_opts, sink)!;
	(void)effects;

	String path_env = comp.environment.has_path ? comp.environment.path : (env::get_var(tmem, "PATH") ?? "");
	String runfiles_dir = comp.environment.has_runfiles_dir ? comp.environment.runfiles_dir : (env::get_var(tmem, "RUNFILES_DIR") ?? (env::get_var(tmem, "TEST_SRCDIR") ?? ""));
	Host host = target::host()!;
	discovery::Env tc_env = {
		.fs = discovery::host_fs(),
		.path = path_env,
		.runfiles_dir = runfiles_dir,
		.process = comp.environment.process,
		.host_is_darwin = host.os.is_darwin(),
		.target = comp.target,
	};
	tc.init(comp.gpa, tc_env, *tc_opts);
	tc.diagnostics = sink;
	fault discover_fault = @catch(tc.discover());
	if (discover_fault)
	{
		tc.free(); return discover_fault~;
	}
	List{IncludeDir} system_includes;
	system_includes.init(comp.gpa);
	defer system_includes.free();
	fault include_fault = @catch(tc.define_system_includes(&system_includes));
	foreach (include : system_includes) owned_include_paths.push(include.path);
	if (include_fault)
	{
		tc.free(); return include_fault~;
	}
	foreach (include : opts.includes) all_includes.push(include);
	foreach (include : system_includes) all_includes.push(include);
	comp.set_include_dirs(all_includes.array_view());
	comp.set_embed_dirs(opts.embed_dirs.array_view());
	return true;
}

fn void print_diagnostics_stats(Diagnostics* d)
{
	if (!d.details) return;
	uint warnings = d.warnings;
	uint errors = d.errors;
	String w_s = warnings == 1 ? "" : "s";
	String e_s = errors == 1 ? "" : "s";
	if (errors != 0 && warnings != 0)
	{
		io::eprintfn("%d warning%s and %d error%s generated.", warnings, w_s, errors, e_s);
	}
	else if (warnings != 0)
	{
		io::eprintfn("%d warning%s generated.", warnings, w_s);
	}
	else if (errors != 0)
	{
		io::eprintfn("%d error%s generated.", errors, e_s);
	}
}

fn bool? write_dependencies(Allocator a, DriverOptions* opts, Source source, dep_file::DepFile* dep)
{
	DString output;
	output.init(a);
	defer output.free();
	dep.write(&output);
	if (opts.has_dependency_file && opts.dependency_file != "-")
	{
		if (catch f = file::save(opts.dependency_file, output.str_view())) return f~;
	}
	else if (!opts.has_dependency_file && opts.write_dependencies)
	{
		String stem = file_stem(opts.has_output_name ? opts.output_name: source.path);
		DString name;
		name.init(a);
		defer name.free();
		name.appendf("%s.d", stem)!!;
		if (catch f = file::save(name.str_view(), output.str_view())) return f~;
	}
	else if (!opts.has_dependency_file && opts.has_output_name && opts.dependency_only)
	{
		if (catch f = file::save(opts.output_name, output.str_view())) return f~;
	}
	else if (catch f = io::write_all(io::stdout(), output.str_view()))
	{
		return f~;
	}
	return true;
}

fn int write_backend_output(Compilation* comp, Diagnostics* d, String output_name, String data, String text = "")
{
	File? output_opt = file::open(output_name, "wb");
	if (catch f = output_opt)
	{
		(void)add_driver_error(comp.gpa, d, "unable to create output file '%s': %s", output_name, f);
		return 1;
	}
	File output = output_opt;
	defer (void)output.close();
	if (catch f = io::write_all(&output, data))
	{
		(void)add_driver_error(comp.gpa, d, "unable to write output file '%s': %s", output_name, f);
		return 1;
	}
	if (text.len != 0)
	{
		if (catch f = io::write_all(&output, text))
		{
			(void)add_driver_error(comp.gpa, d, "unable to write output file '%s': %s", output_name, f);
			return 1;
		}
	}
	return 0;
}

fn void? invoke_assembler(Compilation* comp, Diagnostics* d, toolchain::Toolchain* tc,
	String input_name, String output_name)
{
	ProcessService process = comp.environment.process;
	if (process.run != null && process.run != &host_process::run)
	{
		return driver_exec::invoke_assembler_with_process(tc, d, process, input_name, output_name);
	}
	return driver_exec::invoke_assembler(tc, d, input_name, output_name);
}

fn void? invoke_linker(Compilation* comp, Diagnostics* d, toolchain::Toolchain* tc,
	DriverOptions* opts, String[] link_objects)
{
	String output_name = opts.has_output_name ? opts.output_name : "a.out";
	ProcessService process = comp.environment.process;
	if (process.run != null && process.run != &host_process::run)
	{
		return driver_exec::invoke_linker_with_process(tc, d, process, output_name,
			link_objects, opts.verbose_linker_args);
	}
	return driver_exec::invoke_linker(tc, d, output_name, link_objects, opts.verbose_linker_args);
}

fn int process_backend_source(Compilation* comp, Diagnostics* d, DriverOptions* opts,
	toolchain::Toolchain* tc, driver_tempfiles::DriverTempFiles* temp_files,
	List{String} * link_objects, Source source, tree::Tree* ast,
	preprocessor::Preprocessor* pp, bool link_mode)
{
	if (comp.target.ofmt != target::ObjectFormat.ELF || comp.target.cpu.arch != target::Arch.X86_64)
	{
		(void)add_driver_fatal(comp.gpa, d, "unsupported target %s-%s-%s, currently only x86-64 elf is supported",
			comp.target.cpu.arch.name, comp.target.os.tag.name, comp.target.abi.name);
		return 1;
	}

	String? output_opt = temp_files.get_out_file_name(opts, source, comp.target);
	if (catch f = output_opt)
	{
		(void)add_driver_fatal(comp.gpa, d, "unable to create output file name: %s", f);
		return 1;
	}
	String output_name = output_opt;
	// Every -O level uses the same AST -> IR -> x86_64 pipeline; -O0 just runs
	// no IR passes (`ir_opt::run`), as GCC gates its optimization passes on
	// `optimize`. Zig arocc instead sends -O0 to its data-only assembly stub.
	codegen::TodoReport todo_report;
	todo_report.init(comp.gpa);
	defer todo_report.free();
	ir::Ir? ir_opt = opts.codegen_todo_report ?
		codegen::gen_ir(ast, pp, -1, true, &todo_report) : codegen::gen_ir(ast, pp);
	if (catch f = ir_opt)
	{
		if (f != compilation::FATAL_ERROR)(void)add_driver_fatal(comp.gpa, d, "unable to generate Ir: %s", f);
		return 1;
	}
	ir::Ir generated_ir = ir_opt;
	defer generated_ir.free();
	if (opts.codegen_todo_report)
	{
		return report_ir_todos(comp, d, opts, link_mode, &generated_ir, &todo_report);
	}
	return emit_ir_output(comp, d, opts, tc, temp_files, link_objects, output_name, &generated_ir, link_mode);
}

fn bool use_object_emitter(Compilation* comp, DriverOptions* opts, bool link_mode)
{
	if (opts.only_preprocess_and_compile) return false;
	bool linux = comp.target.os.tag == target::OsTag.LINUX;
	// The in-process static link needs an object regardless of the flag.
	if (link_mode && linux && opts.nostdlib && opts.static_link && !opts.shared && !opts.static_pie) return true;
	if (opts.has_integrated_as) return opts.integrated_as;
	// C3 deviation (like clang): default to the integrated object emitter where it
	// exists. It skips rendering asm text, spawning `as` and re-parsing; on the
	// gcc execute suite it matches the `as` path exactly and halves -c -O0 time.
	return linux && comp.target.cpu.arch == X86_64;
}

fn bool dce_keeps_external_definitions(DriverOptions* opts, bool link_mode)
{
	return !link_mode || opts.shared || opts.rdynamic || opts.link_objects.len() != 0;
}

fn int emit_ir_object(Compilation* comp, Diagnostics* d, DriverOptions* opts,
	List{String} * link_objects, String output_name, ir::Ir* generated_ir, bool link_mode,
	ir::ErrorList* errors)
{
	object::Object*? object_opt = ir::render_object(generated_ir, comp.gpa, comp.target, errors, opts.x86_64_spill_all);
	if (catch f = object_opt)
	{
		if (f == ir::LOWER_FAIL)
		{
			String error_value = errors.len() == 0 ? "unknown lowering error" : errors.message_at(0);
			(void)add_driver_fatal(comp.gpa, d, "unable to render Ir to machine code: %s", error_value);
		}
		else
		{
			(void)add_driver_fatal(comp.gpa, d, "unable to render Ir to machine code: %s", f);
		}
		return 1;
	}
	object::Object* generated_object = object_opt;
	defer generated_object.deinit();
	// in-process link hook
	File? output_opt = file::open(output_name, "wb");
	if (catch f = output_opt)
	{
		(void)add_driver_error(comp.gpa, d, "unable to create output file '%s': %s", output_name, f);
		return 1;
	}
	File output = output_opt;
	defer (void)output.close();
	if (catch f = object::finish(generated_object, &output))
	{
		(void)add_driver_error(comp.gpa, d, "unable to write output file '%s': %s", output_name, f);
		return 1;
	}
	if (opts.only_compile) return 0;
	if (link_mode) link_objects.push(output_name);
	return 0;
}

fn int emit_ir_output(Compilation* comp, Diagnostics* d, DriverOptions* opts,
	toolchain::Toolchain* tc, driver_tempfiles::DriverTempFiles* temp_files,
	List{String} * link_objects, String output_name, ir::Ir* generated_ir, bool link_mode)
{
	ir::ErrorList errors;
	errors.init(comp.gpa);
	defer errors.free();
	fault opt_fault = @catch(ir_opt::run(generated_ir,
			{ .level = comp.code_gen_options.optimization_level, .whole_program = opts.whole_program,
			.verify = opts.verify_ir, .keep_external_definitions = dce_keeps_external_definitions(opts, link_mode) },
		&errors));
	if (opt_fault)
	{
		String error_value = errors.len() == 0 ? "unknown IR optimization error" : errors.message_at(0);
		(void)add_driver_fatal(comp.gpa, d, "IR optimization failed: %s", error_value);
		return 1;
	}
	if (opts.verbose_ir)
	{
		diagnostics::Terminal term = { .writer = io::stdout(), .mode = diagnostics::ColorMode.NO_COLOR };
		if (catch generated_ir.dump(term))
		{
			(void)add_driver_fatal(comp.gpa, d, "unable to write Ir dump");
			return 1;
		}
	}
	if (use_object_emitter(comp, opts, link_mode))
	{
		return emit_ir_object(comp, d, opts, link_objects, output_name, generated_ir, link_mode, &errors);
	}
	// C3 deviation: Zig renders the Ir straight to an object (its x86 renderer is
	// a stub). The port lowers it to assembly text and reuses the assembler path,
	// so -S writes assembly and -c / linking go through the system `as`.
	String? asm_opt = ir::render_asm(generated_ir, comp.gpa, comp.target, &errors, opts.x86_64_spill_all);
	if (catch f = asm_opt)
	{
		if (f == ir::LOWER_FAIL)
		{
			String error_value = errors.len() == 0 ? "unknown lowering error" : errors.message_at(0);
			(void)add_driver_fatal(comp.gpa, d, "unable to render Ir to machine code: %s", error_value);
		}
		else
		{
			(void)add_driver_fatal(comp.gpa, d, "unable to render Ir to machine code: %s", f);
		}
		return 1;
	}
	String asm_text = asm_opt;
	defer alloc::free(comp.gpa, asm_text.ptr);
	return finish_assembly(comp, d, opts, tc, temp_files, link_objects, output_name, link_mode, asm_text, "");
}

<* Collect backend lowering failures and print the combined frontend/backend TODO report. *>
fn int report_ir_todos(Compilation* comp, Diagnostics* d, DriverOptions* opts, bool link_mode,
	ir::Ir* generated_ir, codegen::TodoReport* todo_report)
{
	ir::ErrorList errors;
	errors.init(comp.gpa);
	defer errors.free();
	fault opt_fault = @catch(ir_opt::run(generated_ir,
			{ .level = comp.code_gen_options.optimization_level, .whole_program = opts.whole_program,
			.verify = opts.verify_ir, .keep_external_definitions = dce_keeps_external_definitions(opts, link_mode) },
		&errors));
	if (opt_fault)
	{
		String error_value = errors.len() == 0 ? "unknown IR optimization error" : errors.message_at(0);
		(void)add_driver_fatal(comp.gpa, d, "IR optimization failed: %s", error_value);
		return 1;
	}
	if (opts.verbose_ir)
	{
		diagnostics::Terminal term = { .writer = io::stdout(), .mode = diagnostics::ColorMode.NO_COLOR };
		if (catch generated_ir.dump(term))
		{
			(void)add_driver_fatal(comp.gpa, d, "unable to write Ir dump");
			return 1;
		}
	}

	if (use_object_emitter(comp, opts, link_mode))
	{
		object::Object*? object_opt = ir::render_object(generated_ir, comp.gpa, comp.target, &errors, opts.x86_64_spill_all);
		if (catch f = object_opt)
		{
			if (f != ir::LOWER_FAIL)
			{
				(void)add_driver_fatal(comp.gpa, d, "unable to render Ir to machine code: %s", f);
				return 1;
			}
		}
		else
		{
			object::Object* generated_object = object_opt;
			generated_object.deinit();
		}
	}
	else
	{
		String? asm_opt = ir::render_asm(generated_ir, comp.gpa, comp.target, &errors, opts.x86_64_spill_all);
		if (catch f = asm_opt)
		{
			if (f != ir::LOWER_FAIL)
			{
				(void)add_driver_fatal(comp.gpa, d, "unable to render Ir to machine code: %s", f);
				return 1;
			}
		}
		else
		{
			String asm_text = asm_opt;
			alloc::free(comp.gpa, asm_text.ptr);
		}
	}

	for (usz i = 0; i < errors.len(); i++)
	{
		String kind = string::format(comp.gpa, "x86_64: %s", errors.message_at(i));
		todo_report.record(kind, errors.name_at(i));
		alloc::free(comp.gpa, kind.ptr);
	}

	// Stable in-place selection sort: highest counts first, preserving encounter order on ties.
	for (usz i = 0; i < (usz)todo_report.entries.len(); i++)
	{
		usz best = i;
		for (usz j = i + 1; j < (usz)todo_report.entries.len(); j++)
		{
			if (todo_report.entries.array_view()[j].count > todo_report.entries.array_view()[best].count) best = j;
		}
		if (best != i)
		{
			codegen::TodoReportEntry entry = todo_report.entries.array_view()[i];
			todo_report.entries.array_view()[i] = todo_report.entries.array_view()[best];
			todo_report.entries.array_view()[best] = entry;
		}
	}

	uint skipped = (uint)todo_report.skipped_definitions.len();
	if (catch f = io::fprintf(io::stderr(), "codegen TODO report: %d of %d definitions skipped, %d distinct\n",
			skipped, todo_report.definitions_total, (uint)todo_report.entries.len()))
	{
		(void)add_driver_error(comp.gpa, d, "unable to write codegen TODO report: %s", f);
		return 1;
	}
	foreach (entry : todo_report.entries)
	{
		if (catch f = io::fprintf(io::stderr(), "  %d  %s   (first: %s)\n", entry.count, entry.kind, entry.first_fn))
		{
			(void)add_driver_error(comp.gpa, d, "unable to write codegen TODO report: %s", f);
			return 1;
		}
	}
	return todo_report.entries.len() == 0 ? 0 : 1;
}

<*
 Write generated assembly (`data` then `text`): to `output_name` for -S, else
 through a temporary .s file and the assembler to `output_name`, which is then
 queued for linking in link mode.
*>
fn int finish_assembly(Compilation* comp, Diagnostics* d, DriverOptions* opts,
	toolchain::Toolchain* tc, driver_tempfiles::DriverTempFiles* temp_files,
	List{String} * link_objects, String output_name, bool link_mode, String data, String text)
{
	if (opts.only_preprocess_and_compile) return write_backend_output(comp, d, output_name, data, text);

	String? assembly_name_opt = temp_files.get_random_filename(".s");
	if (catch f = assembly_name_opt)
	{
		(void)add_driver_fatal(comp.gpa, d, "unable to create temporary assembly file name: %s", f);
		return 1;
	}
	String assembly_name = assembly_name_opt;
	if (write_backend_output(comp, d, assembly_name, data, text) != 0) return 1;
	if (catch f = invoke_assembler(comp, d, tc, assembly_name, output_name)) return 1;
	if (opts.only_compile) return 0;
	if (link_mode) link_objects.push(output_name);
	return 0;
}

fn bool merge_conflicts(ir::Decl* existing, ir::Decl* incoming)
{
	if (existing.name != incoming.name) return false;
	if (existing.linkage == ir::Linkage.INTERNAL || incoming.linkage == ir::Linkage.INTERNAL) return false;
	if (existing.kind == ir::DeclKind.GLOBAL && incoming.kind == ir::DeclKind.GLOBAL)
	{
		return existing.is_definition() && incoming.is_definition() &&
		!existing.global.tentative && !incoming.global.tentative;
	}
	if (existing.kind == ir::DeclKind.FUNCTION && incoming.kind == ir::DeclKind.FUNCTION)
	{
		return existing.is_definition() && incoming.is_definition();
	}
	return false;
}

enum GlobalMergeResult : char
{
	NOT_APPLICABLE,
	KEEP_EXISTING,
	REPLACE_EXISTING,
}

fn GlobalMergeResult merge_global_declarations(ir::Decl* existing, ir::Decl* incoming)
{
	if (existing.kind != ir::DeclKind.GLOBAL || incoming.kind != ir::DeclKind.GLOBAL ||
		existing.name != incoming.name || existing.linkage == ir::Linkage.INTERNAL ||
		incoming.linkage == ir::Linkage.INTERNAL)
	{
		return GlobalMergeResult.NOT_APPLICABLE;
	}

	bool existing_definition = existing.is_definition();
	bool incoming_definition = incoming.is_definition();
	if (!existing_definition && incoming_definition)
	{
		return GlobalMergeResult.REPLACE_EXISTING;
	}
	if (existing.global.tentative && incoming_definition && !incoming.global.tentative)
	{
		return GlobalMergeResult.REPLACE_EXISTING;
	}
	if (existing.global.tentative && incoming.global.tentative)
	{
		if (incoming.global.size > existing.global.size) existing.global.size = incoming.global.size;
		if (incoming.global.align > existing.global.align) existing.global.align = incoming.global.align;
	}
	return GlobalMergeResult.KEEP_EXISTING;
}

fn int merge_tu(Compilation* comp, Diagnostics* d, WholeProgram* wp,
	tree::Tree* ast, preprocessor::Preprocessor* pp, int tu_id, Source main_source)
{
	uint errors_before = d.errors;
	ir::Ir? generated_opt = codegen::gen_ir(ast, pp, tu_id);
	if (catch f = generated_opt)
	{
		if (f != compilation::FATAL_ERROR)(void)add_driver_fatal(comp.gpa, d, "unable to generate Ir: %s", f);
		return 1;
	}
	ir::Ir generated = generated_opt;
	defer generated.free();
	ir::Ir accepted;
	accepted.init(comp.gpa, &comp.interner);
	defer accepted.free();

	for (usz incoming_index = 0; incoming_index < (usz)generated.decls.len(); incoming_index++)
	{
		ir::Decl* incoming = &generated.decls.array_view()[incoming_index];
		bool duplicate = false;
		bool handled_global = false;
		bool incoming_moved = false;
		for (usz existing_index = 0; existing_index < (usz)wp.program.decls.len(); existing_index++)
		{
			ir::Decl* existing = &wp.program.decls.array_view()[existing_index];
			if (merge_conflicts(existing, incoming))
			{
				String origin = wp.origins.array_view()[existing_index];
				(void)add_driver_error(comp.gpa, d,
					"multiple definitions of '%s' (in '%s' and '%s')",
					incoming.name, origin, main_source.path);
				duplicate = true;
				break;
			}
			GlobalMergeResult merge_result = merge_global_declarations(existing, incoming);
			if (merge_result == GlobalMergeResult.NOT_APPLICABLE) continue;
			handled_global = true;
			if (merge_result == GlobalMergeResult.REPLACE_EXISTING)
			{
				ir::Decl old = *existing;
				*existing = *incoming;
				old.free();
				wp.origins.array_view()[existing_index] = main_source.path;
				incoming_moved = true;
			}
			break;
		}
		if (duplicate || (handled_global && !incoming_moved)) incoming.free();
		if (!duplicate && !handled_global)
		{
			accepted.decls.push(*incoming);
			wp.origins.push(main_source.path);
		}
	}
	// Accepted declarations have moved to `accepted`; duplicate declarations
	// were freed above. Prevent `generated.free()` from visiting either group.
	generated.decls.clear();
	wp.program.take_decls(&accepted);
	return d.errors == errors_before ? 0 : 1;
}

fn int process_source(Compilation* comp, Diagnostics* d, DriverOptions* opts, FrontendOptions* extra,
	toolchain::Toolchain* tc, driver_tempfiles::DriverTempFiles* temp_files,
	List{String} * link_objects, bool link_mode,
	Source main_source, Source builtin_source, Source command_line_source,
	Source[] imacros, Source[] implicit_includes, WholeProgram* wp = null, int tu_id = -1)
{
	comp.generated_buf.clear();
	uint errors_before = d.errors;
	dep_file::DepFile dep;
	bool wants_dependencies = opts.dependency_only || opts.write_dependencies;
	DString dep_target;
	dep_target.init(comp.gpa);
	defer dep_target.free();
	String stem = file_stem(main_source.path);
	dep_target.appendf("%s%s", stem, comp.target.ofmt.file_ext(comp.target.cpu.arch))!!;
	if (opts.write_dependencies && opts.has_output_name)
	{
		dep_target.clear();
		dep_target.append_string(opts.output_name);
	}
	dep.init(comp.gpa, dep_target.str_view(), opts.dependency_nmake ? dep_file::Format.NMAKE : dep_file::Format.MAKE);
	defer dep.free();

	preprocessor::Preprocessor pp;
	preprocessor::InitOptions pp_opts = {
		.base_file = main_source.id,
		.add_builtin_macros = true,
		.dependencies = wants_dependencies ? &dep : null,
	};
	if (catch f = pp.init(comp, pp_opts, preprocessor::BUILTINS, comp.file_provider()))
	{
		(void)add_driver_error(comp.gpa, d, "unable to initialize preprocessor: %s", f);
		return 1;
	}
	defer pp.free();
	if (opts.verbose_pp) pp.verbose = true;
	preprocessor::DumpMode dump_mode = extra.dump_mode();
	if (opts.only_preprocess)
	{
		pp.preserve_whitespace = true;
		if (opts.line_commands) pp.linemarkers = opts.use_line_directives ? preprocessor::Linemarkers.LINE_DIRECTIVES : preprocessor::Linemarkers.NUMERIC_DIRECTIVES;
		if (dump_mode == preprocessor::DumpMode.MACROS_AND_RESULT || dump_mode == preprocessor::DumpMode.MACRO_NAMES_AND_RESULT) pp.store_macro_tokens = true;
	}
	preprocessor::PreprocessSources sources = {
		.main = main_source,
		.builtin = builtin_source,
		.has_command_line = true,
		.command_line = command_line_source,
		.imacros = imacros,
		.implicit_includes = implicit_includes,
	};
	if (catch f = pp.preprocess_sources(sources))
	{
		comp.pragmas.after_parse(comp);
		if (f != compilation::FATAL_ERROR)(void)add_driver_error(comp.gpa, d, "preprocessing failed: %s", f);
		print_diagnostics_stats(d);
		return 1;
	}

	if (wants_dependencies)
	{
		if (catch f = write_dependencies(comp.gpa, opts, main_source, &dep))
		{
			(void)add_driver_error(comp.gpa, d, "unable to write dependency output: %s", f);
			print_diagnostics_stats(d);
			return 1;
		}
	}

	if (opts.dependency_only)
	{
		comp.pragmas.after_parse(comp);
		print_diagnostics_stats(d);
		return d.errors == errors_before ? 0 : 1;
	}

	if (opts.only_preprocess)
	{
		comp.pragmas.after_parse(comp);
		print_diagnostics_stats(d);
		if (opts.has_output_name && opts.output_name != "-")
		{
			File? output_file = file::open(opts.output_name, "wb");
			if (catch f = output_file)
			{
				(void)add_driver_error(comp.gpa, d, "unable to create output file '%s': %s", opts.output_name, f);
				return 1;
			}
			File output = output_file;
			if (catch f = pp.pretty_print_tokens(&output, dump_mode))
			{
				(void)output.close();
				(void)add_driver_error(comp.gpa, d, "unable to write result: %s", f);
				return 1;
			}
			if (catch f = output.close())
			{
				(void)add_driver_error(comp.gpa, d, "unable to close result file '%s': %s", opts.output_name, f);
				return 1;
			}
		}
		else if (catch f = pp.pretty_print_tokens(io::stdout(), dump_mode))
		{
			(void)add_driver_error(comp.gpa, d, "unable to write result: %s", f);
			return 1;
		}
		return 0;
	}

	parser::Parser p;
	p.init(&pp);
	parser_frontend::FrontendHandler handler;
	handler.bind(&p);
	defer p.free();
	tree::Tree? parsed = p.parse();
	if (catch f = parsed)
	{
		if (f != compilation::FATAL_ERROR)(void)add_driver_error(comp.gpa, d, "parser failed: %s", f);
		print_diagnostics_stats(d);
		return 1;
	}
	tree::Tree result = parsed;
	defer result.free();
	if (opts.verbose_ast)
	{
		diagnostics::Terminal term = { .writer = io::stdout(), .mode = diagnostics::ColorMode.NO_COLOR };
		if (catch result.dump(term))
		{
			(void)add_driver_fatal(comp.gpa, d, "unable to write AST");
			return 1;
		}
	}
	print_diagnostics_stats(d);
	if (d.errors != errors_before) return 1;
	if (opts.only_syntax) return 0;
	if (wp != null) return merge_tu(comp, d, wp, &result, &pp, tu_id, main_source);
	return process_backend_source(comp, d, opts, tc, temp_files, link_objects, main_source, &result, &pp, link_mode);
}

<* Execute the production CLI. `executable_dir` is the containing directory
 of the executable, as supplied by Zig's `executableDirPathAlloc`. *>
fn int run(Compilation* comp, Diagnostics* d, String[] args, String executable_dir)
{
	return run_with_stdin(comp, d, args, executable_dir, io::stdin());
}

<* Merge user linker inputs and generated source objects at the argv positions
 recorded for each translation unit. *>
fn void merge_link_inputs(String[] user, usz[] slots, String[] compiled, usz[] tu_end,
	bool whole_program, List{String} * out)
{
	if (whole_program)
	{
		usz object_slot = slots.len == 0 ? 0 : slots[0];
		for (usz slot = 0; slot <= user.len; slot++)
		{
			if (slot == object_slot) out.push_all(compiled);
			if (slot < user.len) out.push(user[slot]);
		}
		return;
	}
	usz object_begin = 0;
	usz tu = 0;
	for (usz slot = 0; slot <= user.len; slot++)
	{
		while (tu < slots.len && slots[tu] == slot)
		{
			usz object_end = tu_end[tu];
			for (usz object = object_begin; object < object_end; object++) out.push(compiled[object]);
			object_begin = object_end;
			tu++;
		}
		if (slot < user.len) out.push(user[slot]);
	}
}

<* Test seam for CLI stdin; production callers should use `run`. *>
fn int run_with_stdin(Compilation* comp, Diagnostics* d, String[] args,
	String executable_dir, File* stdin_file)
{
	DriverOptions opts;
	opts.init(comp.gpa);
	defer opts.free();
	FrontendOptions extra;
	extra.init(comp.gpa);
	defer extra.free();
	List{String} filtered;
	filtered.init(comp.gpa);
	defer filtered.free();
	if (catch f = filter_frontend_args(args, &filtered, &extra))
	{
		(void)add_driver_error(comp.gpa, d, f == MISSING_ARGUMENT ? "expected argument after CLI option" : "invalid command line");
		return 1;
	}
	ArgumentResult parsed;
	uint errors_before_parse = d.errors;
	ArgumentResult? parse_result = parse_args(&opts, filtered.array_view(), d);
	if (catch f = parse_result)
	{
		if (d.errors > errors_before_parse) return 1;
		String message = f == MISSING_ARGUMENT ? "expected argument after command-line option" : f == INVALID_TARGET ? "invalid target" : "invalid command-line argument";
		(void)add_driver_error(comp.gpa, d, "%s", message);
		return 1;
	}
	parsed = parse_result;
	if (parsed.action == HELP)
	{
		String output = usage_text(comp.gpa, args[0]);
		defer alloc::free(comp.gpa, output.ptr);
		io::printf("%s", output);
		return 0;
	}
	if (parsed.action == VERSION)
	{
		String output = version_text(comp.gpa);
		defer alloc::free(comp.gpa, output.ptr);
		io::printf("%s", output);
		return 0;
	}
	if (d.errors > errors_before_parse) return 1;
	uint errors_before_run = d.errors;
	diagnostics::State old_diagnostic_state = d.state;
	defer
	{
		d.state = old_diagnostic_state;
	};
	if (extra.has_color)
	{
		d.color = extra.color ? diagnostics::ColorOverride.FORCE_ON : diagnostics::ColorOverride.FORCE_OFF;
		d.terminal.mode = extra.color ? diagnostics::ColorMode.ESCAPE_CODES : diagnostics::ColorMode.NO_COLOR;
	}
	if (opts.inputs.len() == 0)
	{
		(void)add_driver_fatal(comp.gpa, d, "no input files");
		return 1;
	}
	if (opts.codegen_todo_report && opts.whole_program)
	{
		(void)add_driver_error(comp.gpa, d, "--codegen-todo-report is not supported with -fwhole-program");
		return 1;
	}
	bool link_mode = !(opts.only_preprocess || opts.only_syntax || opts.only_compile || opts.only_preprocess_and_compile);
	bool whole_program = opts.whole_program && !(opts.only_preprocess || opts.only_syntax || opts.dependency_only);
	if (opts.has_output_name && opts.inputs.len() != 1 && !link_mode && !whole_program)
	{
		(void)add_driver_fatal(comp.gpa, d, "cannot specify -o when generating multiple output files");
		return 1;
	}
	if (catch f = apply_diagnostic_options(args, d))
	{
		(void)add_driver_error(comp.gpa, d, "invalid warning option: %s", f);
		return 1;
	}
	if (!link_mode && opts.link_objects.len() != 0)
	{
		foreach (obj : opts.link_objects)(void)add_driver_error(comp.gpa, d,
			"%s: linker input file unused because linking not done", obj);
	}

	bool set_cwd = false;
	String old_cwd = comp.cwd;
	if (comp.cwd.len == 0)
	{
		path::Path? cwd = path::cwd(comp.gpa);
		if (catch f = cwd)
		{
			(void)add_driver_error(comp.gpa, d, "unable to determine current directory: %s", f);
			return 1;
		}
		comp.cwd = (String)cwd;
		set_cwd = true;
	}
	defer if (set_cwd)
	{
		alloc::free(comp.gpa, comp.cwd.ptr);
		comp.cwd = old_cwd;
	};
	install_default_file_services(comp);
	install_default_pragmas(comp);

	String old_epoch = comp.environment.source_date_epoch;
	bool old_has_epoch = comp.environment.has_source_date_epoch;
	if (!comp.environment.has_source_date_epoch)
	{
		if (try epoch = env::get_var(tmem, "SOURCE_DATE_EPOCH"))
		{
			comp.environment.has_source_date_epoch = true;
			comp.environment.source_date_epoch = epoch;
		}
	}
	defer
	{
		comp.environment.source_date_epoch = old_epoch; comp.environment.has_source_date_epoch = old_has_epoch;
	};

	toolchain::Options tc_opts;
	toolchain::Toolchain tc;
	tc_opts.aro_name = executable_dir;
	List{IncludeDir} all_includes;
	all_includes.init(comp.gpa);
	defer all_includes.free();
	List{String} owned_include_paths;
	owned_include_paths.init(comp.gpa);
	uint errors_before_configure = d.errors;
	defer
	{
		foreach (p : owned_include_paths) alloc::free(comp.gpa, p.ptr); owned_include_paths.free();
	};
	if (catch f = configure_toolchain(comp, &opts, &tc_opts, &tc, &all_includes, &owned_include_paths, d))
	{
		if (d.errors > errors_before_configure) return 1;
		String message = toolchain_fault_message(f);
		if (f == multilib::TOO_MANY_MULTILIBS)
		{
			(void)add_driver_fatal(comp.gpa, d, "%s", message);
		}
		else
		{
			(void)add_driver_error(comp.gpa, d, "%s", message);
		}
		return 1;
	}
	defer tc.free();
	driver_tempfiles::DriverTempFiles temp_files;
	temp_files.init(comp.gpa);
	defer temp_files.free();
	List{String} compiled_objects;
	compiled_objects.init(comp.gpa);
	defer compiled_objects.free();
	List{usz} tu_object_end;
	tu_object_end.init(comp.gpa);
	defer tu_object_end.free();
	WholeProgram wp;
	wp.init(comp.gpa, &comp.interner);
	defer wp.free();
	if (whole_program && (comp.target.ofmt != target::ObjectFormat.ELF || comp.target.cpu.arch != target::Arch.X86_64))
	{
		(void)add_driver_fatal(comp.gpa, d, "unsupported target %s-%s-%s, currently only x86-64 elf is supported",
			comp.target.cpu.arch.name, comp.target.os.tag.name, comp.target.abi.name);
		return 1;
	}

	if (opts.has_standard) comp.langopts.set_standard(opts.standard)!!;
	Source? command_line_opt = make_command_line_source(comp, &opts);
	if (catch f = command_line_opt)
	{
		(void)add_driver_error(comp.gpa, d, "unable to create command-line macro source: %s", f);
		return 1;
	}
	Source command_line_source = command_line_opt;
	SystemDefinesMode system_defines = opts.no_system_defines ? predefined_macros::SystemDefinesMode.NO_SYSTEM_DEFINES : predefined_macros::SystemDefinesMode.INCLUDE_SYSTEM_DEFINES;
	Source? builtin_opt = predefined_macros::generate_builtin_macros(comp, system_defines);
	if (catch f = builtin_opt)
	{
		(void)add_driver_error(comp.gpa, d, "unable to create builtin macro source: %s", f);
		return 1;
	}
	Source builtin_source = builtin_opt;
	List{Source} imacros;
	imacros.init(comp.gpa);
	defer imacros.free();
	foreach (path_arg : extra.imacros)
	{
		Source? source_opt = load_cli_include(comp, path_arg);
		if (catch f = source_opt)
		{
			if (f == CLI_INCLUDE_NOT_FOUND)
			{
				(void)add_driver_error(comp.gpa, d, "imacros file '%s' was not found", path_arg);
			}
			else
			{
				(void)add_driver_error(comp.gpa, d, "unable to add imacros file '%s': %s", path_arg, f);
			}
			return 1;
		}
		imacros.push(source_opt);
	}
	List{Source} implicit_includes;
	implicit_includes.init(comp.gpa);
	defer implicit_includes.free();
	foreach (path_arg : extra.implicit_includes)
	{
		Source? source_opt = load_cli_include(comp, path_arg);
		if (catch f = source_opt)
		{
			if (f == CLI_INCLUDE_NOT_FOUND)
			{
				(void)add_driver_error(comp.gpa, d, "implicit include file '%s' was not found", path_arg);
			}
			else
			{
				(void)add_driver_error(comp.gpa, d, "unable to add implicit include file '%s': %s", path_arg, f);
			}
			return 1;
		}
		implicit_includes.push(source_opt);
	}

	int status = 0;
	int tu_id = 0;
	Source output_source = {};
	foreach (input_path : opts.inputs)
	{
		int this_tu_id = tu_id;
		tu_id++;
		char[]? input_bytes;
		if (input_path == "-")
		{
			input_bytes = read_stdin(comp.gpa, stdin_file);
		}
		else if (try existing = comp.find_source(input_path))
		{
			input_bytes = existing.buf.copy(comp.gpa);
		}
		else
		{
			input_bytes = file::load(comp.gpa, input_path);
		}
		if (catch f = input_bytes)
		{
			(void)add_driver_error(comp.gpa, d, "unable to read input '%s': %s", input_path, f);
			status = 1;
			continue;
		}
		char[] contents = input_bytes;
		defer alloc::free(comp.gpa, contents.ptr);
		String logical_path = input_path == "-" ? "<stdin>" : input_path;
		Source? source_opt = comp.add_source_from_buffer(logical_path, contents);
		if (catch f = source_opt)
		{
			(void)add_driver_error(comp.gpa, d, "unable to add input '%s': %s", input_path, f);
			status = 1;
			continue;
		}
		if (this_tu_id == 0) output_source = source_opt;
		int file_status = process_source(comp, d, &opts, &extra,
			&tc, &temp_files, &compiled_objects, link_mode, source_opt, builtin_source,
			command_line_source, imacros.array_view(), implicit_includes.array_view(),
		whole_program ? &wp: null, this_tu_id);
		tu_object_end.push((usz)compiled_objects.len());
		if (file_status != 0) status = file_status;
	}
	if (d.errors != errors_before_run) return 1;
	if (status != 0) return status;
	if (whole_program)
	{
		String? output_opt = temp_files.get_out_file_name(&opts, output_source, comp.target);
		if (catch f = output_opt)
		{
			(void)add_driver_fatal(comp.gpa, d, "unable to create output file name: %s", f);
			return 1;
		}
		if (emit_ir_output(comp, d, &opts, &tc, &temp_files, &compiled_objects,
				output_opt, &wp.program, link_mode) != 0) return 1;
	}
	if (link_mode)
	{
		List{String} merged_link_inputs;
		merged_link_inputs.init(comp.gpa);
		defer merged_link_inputs.free();
		merge_link_inputs(opts.link_objects.array_view(), opts.input_link_slots.array_view(),
		compiled_objects.array_view(), tu_object_end.array_view(), whole_program, &merged_link_inputs);
		if (catch f = invoke_linker(comp, d, &tc, &opts, merged_link_inputs.array_view()))
		{
			(void)f;
			return 1;
		}
	}
	// Zig Debug -E exits with status 1 after printing diagnostics. Other modes
	// follow main.zig:102, including non-fatal link-time policy errors.
	if (d.errors != errors_before_run) return 1;
	return status;
}
