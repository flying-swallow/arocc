// frontend_probe: preprocessing plus the parser context's current
// syntax/verbose-AST boundary for migration runner cases.
//
//   frontend_probe -fno-color-diagnostics <file> -E -P [manifest args]
//
// and mirrors what src/aro/Driver.zig does for them (parseArgs for the
// supported options, processSource's -E branch, main.zig's exit handling in
// release mode): diagnostics are rendered to stderr following the Zig
// driver's source-derived no-color path, and the -E output (prettyPrintTokens) goes
// to stdout.
//
// Supported options (everything else fails loudly, see below):
//   -E, -P / --no-line-commands, -fuse-line-directives, -fno-use-line-directives,
//   -dM, -dD, -dN, -D<m>[=<v>] / -D <m>, -U<m> / -U <m>, -std=<s>,
//   --emulate=clang|gcc|msvc, -pedantic, -pedantic-errors, -w, -W<x>, -Wno-<x>,
//   -Werror, -Wno-error, -Werror=<x>, -Wno-error=<x>, -Wfatal-errors,
//   -Wno-fatal-errors, -Weverything, -Wno-everything, -Wsystem-headers,
//   -Wno-system-headers, -C / --comments, -CC / --comments-in-macros,
//   -fms-extensions, -fno-ms-extensions, -fdollars-in-identifiers,
//   -fno-dollars-in-identifiers, -fdigraphs, -fno-digraphs,
//   --target=<triple> / --target <triple>, -mcpu=<cpu> / -mcpu <cpu>,
//   -I<dir> / -I <dir>, -iquote, -isystem, -idirafter, -F<dir> / -F <dir>,
//   -M (Make dependency output), -fno-color-diagnostics,
//   -fsyntax-only [--verbose-ast]: dispatches preprocessed tokens through the
//     parser context. The probe binds parser_declaration's declaration,
//     type-name, and body grammar, plus the parser-owned expression composition
//     and its specialized builtin, initializer, compound-literal, and
//     statement-expression hooks. Declaration fixtures exercise normal parser
//     diagnostics and recovery, including a malformed function followed by a
//     valid declaration.
//
// Differences from the real driver, by construction:
//   - Builtin macros and #pragma once are provided by the C3 port. This probe
//     registers handlers for GCC, once, and message pragmas; other unknown
//     pragmas remain in the output stream.
//   - #include / #embed and __has_include use Compilation's ordered filesystem
//     search. Include directories and inputs are relative to the case cwd set
//     by the migration runner. -M records main, included, and embedded paths.
//   - The source epoch honors SOURCE_DATE_EPOCH; the fallback clock is fixed
//     for reproducibility. __TIMESTAMP__ uses mtime unless the epoch is set.
//
// "Fail loudly": probe-level problems are printed as
//   frontend_probe: error: <reason>
// on stderr with exit status 2. The line contains "error: ", so the runner
// counts it as an unexpected diagnostic even for expand_error cases that
// expect no diagnostics.
//
// Exit status otherwise follows the Zig release build: -E exits 0 after
// printing (Driver.processSource fast_exit), a fatal error exits 1, and
// -fsyntax-only exits 1 when errors were emitted.
module frontend_probe;
import aro::compilation, aro::driver, aro::driver_options, aro::include_search, aro::diagnostics, aro::preprocessor, aro::source, aro::tokens, aro::tokenizer, aro::lang_opts, aro::target, aro::predefined_macros, aro::parser, aro::parser_frontend, aro::tree, aro::type_store;
import std::io, std::io::os, std::os::env, std::collections::list;
import aro::dep_file, aro::pragma, aro::pragmas::gcc, aro::pragmas::once, aro::pragmas::message;

excuse PROBE_FAILED;

fn void probe_error(String fmt, args...)
{
	io::eprint("frontend_probe: error: ");
	io::eprintfn(fmt, ...args);
}

struct Options
{
	String input;
	bool only_preprocess;
	bool only_syntax;
	bool dependencies;
	bool verbose_ast;
	bool line_commands;
	bool use_line_directives;
	bool dump_d;
	bool dump_m;
	bool dump_n;
	bool has_emulate;
	Compiler emulate;
	bool has_ms_extensions;
	bool ms_extensions;
	String comment_arg;
	String target_triple;
	String target_cpu;
	List{IncludeDir} include_dirs;
}

fn bool probe_file_exists(void* ctx, String path) => file::is_file(path);

fn char[]? probe_read_file(void* ctx, Allocator a, String path, ulong limit)
{
	char[]? data = file::load(a, path);
	if (catch data) return preprocessor::FILE_NOT_FOUND~;
	if (limit != ulong::max && (ulong)data.len > limit) data = data[:(usz)limit];
	return data;
}

fn ulong? probe_file_mtime(void* ctx, String path)
{
	return (ulong)(os::native_get_modified_time(path) ?? 0);
}

<* Zig `option`: `arg` starts with `name` and has something after it. *>
fn String? option(String arg, String name)
{
	if (arg.starts_with(name) && arg.len > name.len) return arg[name.len..];
	return PROBE_FAILED~;
}

<* Zig `getPreprocessorDumpMode`: -dM wins over -dD over -dN. *>
fn DumpMode Options.dump_mode(&self)
{
	if (self.dump_m) return MACROS_ONLY;
	if (self.dump_d) return MACROS_AND_RESULT;
	if (self.dump_n) return MACRO_NAMES_AND_RESULT;
	return RESULT_ONLY;
}

<* Zig `printDiagnosticsStats` (std.debug.print goes to stderr). *>
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


<* These options already have a reusable home in aro::driver. Keep the
 probe-specific diagnostic policy and emulation flags in this adapter. *>
fn bool shared_option(String arg)
{
	return arg == "-D" || arg.starts_with("-D") || arg == "-U" || arg.starts_with("-U") ||
		arg == "-I" || arg.starts_with("-I") || arg == "-iquote" || arg.starts_with("-iquote") ||
		arg == "-isystem" || arg.starts_with("-isystem") || arg == "-idirafter" || arg.starts_with("-idirafter") ||
		arg == "-F" || arg.starts_with("-F") || arg == "--target" || arg == "-target" || arg.starts_with("--target=") ||
		arg == "-mcpu" || arg.starts_with("-mcpu=") || arg == "-std" || arg.starts_with("-std=") ||
		arg == "-M" || arg == "--dependencies" || arg == "-E" || arg == "-P" || arg == "--no-line-commands" ||
		arg == "-fuse-line-directives" || arg == "-fno-use-line-directives" || arg == "-fsyntax-only" ||
		arg == "--verbose-ast" || arg == "-C" || arg == "--comments" || arg == "-CC" || arg == "--comments-in-macros";
}

fn bool shared_option_takes_value(String arg)
{
	return arg == "-D" || arg == "-U" || arg == "-I" || arg == "-iquote" || arg == "-isystem" ||
		arg == "-idirafter" || arg == "-F" || arg == "--target" || arg == "-target" || arg == "-mcpu" || arg == "-std";
}

<* Parse shared command-line options with aro::driver, then apply the probe's
 adapter-only flags. The filtered argv keeps the driver's parser authoritative
 for inputs, targets, includes, standards, macros, and frontend modes. *>
fn void? parse_args(String[] args, Options* o, Compilation* comp, Diagnostics* d, DString* macro_buf)
{
	DriverOptions shared;
	shared.init(mem);
	defer shared.free();
	List{String} shared_args;
	shared_args.init(mem);
	defer shared_args.free();
	List{String} probe_args;
	probe_args.init(mem);
	defer probe_args.free();
	if (args.len) shared_args.push(args[0]);

	bool saw_preprocess = false;
	bool saw_dependencies = false;
	for (sz i = 1; i < args.len; i++)
	{
		String arg = args[i];
		if (shared_option(arg))
		{
			// The shared parser accepts attached -D/-U/-I/--target/-mcpu/-std,
			// while its other path options use a separate argument.
			if (arg.starts_with("-iquote") && arg != "-iquote")
			{
				shared_args.push("-iquote");
				shared_args.push(arg[7..]);
			}
			else if (arg.starts_with("-isystem") && arg != "-isystem")
			{
				shared_args.push("-isystem");
				shared_args.push(arg[8..]);
			}
			else if (arg.starts_with("-idirafter") && arg != "-idirafter")
			{
				shared_args.push("-idirafter");
				shared_args.push(arg[10..]);
			}
			else if (arg.starts_with("-F") && arg != "-F")
			{
				shared_args.push("-F");
				shared_args.push(arg[2..]);
			}
			else { shared_args.push(arg); }
			if (arg == "-E") saw_preprocess = true;
			if (arg == "-M" || arg == "--dependencies") saw_dependencies = true;
			if (arg == "-C" || arg == "--comments" || arg == "-CC" || arg == "--comments-in-macros") o.comment_arg = arg;
			if (shared_option_takes_value(arg))
			{
				if (i + 1 >= args.len)
				{
					probe_error("expected argument after %s", arg);
					return PROBE_FAILED~;
				}
				shared_args.push(args[++i]);
			}
		}
		else if (arg.len <= 1 || arg[0] != '-') { shared_args.push(arg); }
		else { probe_args.push(arg); }
	}

	ArgumentResult? parsed = driver::parse_args(&shared, shared_args.array_view());
	if (catch f = parsed)
	{
		if (f == driver::MISSING_ARGUMENT) { probe_error("missing argument in command line"); }
		else { probe_error("invalid shared command-line option"); }
		return PROBE_FAILED~;
	}
	sz input_count = shared.inputs.len() + shared.link_objects.len();
	if (input_count == 0)
	{
		probe_error("no input files");
		return PROBE_FAILED~;
	}
	if (input_count > 1)
	{
		String first = shared.inputs.len() ? shared.inputs.get(0) : shared.link_objects.get(0);
		String second = shared.inputs.len() > 1 ? shared.inputs.get(1) : shared.link_objects.get(0);
		if (!shared.inputs.len()) second = shared.link_objects.get(1);
		probe_error("only one input file is supported ('%s' and '%s')", first, second);
		return PROBE_FAILED~;
	}
	o.input = shared.inputs.len() ? shared.inputs.get(0) : shared.link_objects.get(0);
	o.only_preprocess = saw_preprocess;
	o.dependencies = saw_dependencies;
	o.only_syntax = shared.only_syntax;
	o.verbose_ast = shared.verbose_ast;
	o.line_commands = shared.line_commands;
	o.use_line_directives = shared.use_line_directives;
	o.dump_d = false;
	o.dump_m = false;
	o.dump_n = false;
	if (shared.has_target_triple) o.target_triple = shared.target_triple;
	if (shared.has_cpu) o.target_cpu = shared.cpu;
	foreach (include_dir : shared.includes) o.include_dirs.push(include_dir);
	comp.langopts.preserve_comments = shared.preserve_comments;
	comp.langopts.preserve_comments_in_macros = shared.preserve_comments_in_macros;
	if (shared.has_standard)
	{
		if (catch comp.langopts.set_standard(shared.standard))
		{
			probe_error("invalid standard '-std=%s'", shared.standard);
			return PROBE_FAILED~;
		}
	}
	foreach (effect : shared.macro_effects)
	{
		if (effect.kind == driver_options::ParseEffectKind.DEFINE)
		{
			String m = effect.value;
			String value = "1";
			if (try eq = m.index_of_char('='))
			{
				value = m[eq + 1..];
				m = m[:eq];
			}
			macro_buf.appendf("#define %s %s\n", m, value);
		}
		else { macro_buf.appendf("#undef %s\n", effect.value); }
	}

	// Options that affect diagnostics or language parsing but are not part of
	// the reusable driver parser remain local to the migration probe.
	foreach (arg : probe_args)
	{
		switch (arg)
		{
			case "-dD": o.dump_d = true;
			case "-dM": o.dump_m = true;
			case "-dN": o.dump_n = true;
			case "-fno-color-diagnostics": break; // output is never colored
			case "-fms-extensions": o.has_ms_extensions = true; o.ms_extensions = true;
			case "-fno-ms-extensions": o.has_ms_extensions = true; o.ms_extensions = false;
			case "-fdollars-in-identifiers": comp.langopts.dollars_in_identifiers = true;
			case "-fno-dollars-in-identifiers": comp.langopts.dollars_in_identifiers = false;
			case "-fdigraphs": comp.langopts.digraphs = ON;
			case "-fno-digraphs": comp.langopts.digraphs = OFF;
			case "-pedantic": d.state.extensions = WARNING;
			case "-pedantic-errors": d.state.extensions = ERROR;
			case "-w": d.state.ignore_warnings = true;
			case "-Wno-fatal-errors": d.state.fatal_errors = false;
			case "-Wfatal-errors": d.state.fatal_errors = true;
			case "-Wno-everything": d.state.enable_all_warnings = false;
			case "-Weverything": d.state.enable_all_warnings = true;
			case "-Wno-system-headers": d.state.suppress_system_headers = true;
			case "-Wsystem-headers": d.state.suppress_system_headers = false;
			case "-Werror": d.state.error_warnings = true;
			case "-Wno-error": d.state.error_warnings = false;
			default:
				if (try name = option(arg, "--emulate="))
				{
					switch (name)
					{
						case "clang": o.emulate = CLANG;
						case "gcc": o.emulate = GCC;
						case "msvc": o.emulate = MSVC;
						default: probe_error("invalid compiler '%s'", arg); return PROBE_FAILED~;
					}
					o.has_emulate = true;
				}
				else if (try name = option(arg, "-Werror=")) { d.set(name, ERROR)!; }
				else if (try name = option(arg, "-Wno-error=")) { d.set(name, WARNING)!; }
				else if (try name = option(arg, "-Wno-")) { d.set(name, OFF)!; }
				else if (try name = option(arg, "-W")) { d.set(name, WARNING)!; }
				else { probe_error("unsupported option '%s'", arg); return PROBE_FAILED~; }
		}
	}
	if (o.target_triple.len)
	{
		Target? parsed_target = target::parse_triple(o.target_triple, target::host()!!, o.target_cpu);
		if (catch parsed_target)
		{
			probe_error("invalid target '%s' with CPU '%s'", o.target_triple, o.target_cpu);
			return PROBE_FAILED~;
		}
		comp.target = parsed_target;
	}
	else if (o.target_cpu.len)
	{
		probe_error("-mcpu requires an explicit --target");
		return PROBE_FAILED~;
	}
	// Driver.parseArgs tail and main(): emulation, MS extensions, checks.
	if (o.has_emulate)
	{
		comp.langopts.set_emulated_compiler(o.emulate);
		switch (comp.langopts.emulate)
		{
			case CLANG: d.set("clang", OFF)!;
			case GCC: d.set("gnu", OFF)!;
			case MSVC: d.set("microsoft", OFF)!;
			case NO: break;
		}
	}
	if (o.has_ms_extensions) comp.langopts.set_ms_extensions(o.ms_extensions);
	if ((o.only_preprocess ? 1 : 0) + (o.only_syntax ? 1 : 0) + (o.dependencies ? 1 : 0) != 1)
	{
		probe_error("exactly one of -E, -M, or -fsyntax-only is required");
		return PROBE_FAILED~;
	}
	if (o.verbose_ast && !o.only_syntax)
	{
		probe_error("--verbose-ast requires -fsyntax-only");
		return PROBE_FAILED~;
	}
	if (comp.langopts.preserve_comments && !o.only_preprocess)
	{
		probe_error("invalid argument '%s' only allowed with '-E'", o.comment_arg);
		return PROBE_FAILED~;
	}
	if (o.only_syntax && (o.dump_d || o.dump_m || o.dump_n))
	{
		probe_error("-d<letter> requires -E");
		return PROBE_FAILED~;
	}
}

<* Preprocess and print. Returns the process exit status. *>
fn int run(String[] args, Compilation* comp, Diagnostics* d)
{
	Options o;
	o.include_dirs.init(mem);
	defer o.include_dirs.free();
	DString macro_buf;
	macro_buf.init(mem);
	defer macro_buf.free();
	if (catch parse_args(args, &o, comp, d, &macro_buf)) return 2;
	comp.cwd = ".";
	comp.set_include_dirs(o.include_dirs.array_view());
	comp.include_files = { .exists = &probe_file_exists, .read = &probe_read_file, .mtime = &probe_file_mtime };

	char[]? contents = file::load(mem, o.input);
	if (catch err = contents)
	{
		probe_error("unable to read '%s': %s", o.input, err);
		return 2;
	}
	defer free(contents.ptr);
	// Driver order: inputs while parsing args, then "<command line>", then "<builtin>".
	Source? main_src = comp.add_source_from_buffer(o.input, contents);
	if (catch main_src)
	{
		print_diagnostics_stats(d);
		return 1;
	}
	Source? cmd_src = comp.add_source_from_buffer("<command line>", macro_buf.str_view());
	if (catch cmd_src) return 1;
	Source? builtin_src = predefined_macros::generate_builtin_macros(comp, predefined_macros::SystemDefinesMode.INCLUDE_SYSTEM_DEFINES);
	if (catch builtin_src) return 1;

	Preprocessor pp;
	DepFile dep;
	if (o.dependencies) dep.init(mem, o.input, MAKE);
	defer if (o.dependencies) dep.free();
	InitOptions init_opts = {
		.base_file = main_src.id,
		.add_builtin_macros = true,
		.dependencies = o.dependencies ? &dep : null,
	};
	if (catch f = pp.init(comp, init_opts, preprocessor::BUILTINS, comp.file_provider()))
	{
		probe_error("preprocessor init failed: %s", f);
		return 2;
	}
	defer pp.free();

	DumpMode dump_mode = o.dump_mode();
	if (o.only_preprocess)
	{
		pp.preserve_whitespace = true;
		if (o.line_commands) pp.linemarkers = o.use_line_directives ? LINE_DIRECTIVES : NUMERIC_DIRECTIVES;
		switch (dump_mode)
		{
			case MACROS_AND_RESULT:
			case MACRO_NAMES_AND_RESULT:
				pp.store_macro_tokens = true;
			case RESULT_ONLY:
			case MACROS_ONLY:
				break;
		}
	}

	PreprocessSources sources = { .main = main_src, .builtin = builtin_src, .has_command_line = true, .command_line = cmd_src };
	if (catch f = pp.preprocess_sources(sources))
	{
		if (f == compilation::FATAL_ERROR)
		{
			// main.zig: error.FatalError -> printDiagnosticsStats, exit 1.
			print_diagnostics_stats(d);
			return 1;
		}
		probe_error("preprocessing stopped: %s (not implemented in the C3 port yet)", f);
		return 2;
	}

	if (o.only_syntax || dump_mode != MACROS_ONLY)
	{
		// pretty_print_tokens (like Zig) walks the tokens until eof.
		if (pp.tokens.len() == 0 || pp.tokens[pp.tokens.len() - 1].id != EOF)
		{
			probe_error("preprocessing did not end the translation unit with an eof token");
			return 2;
		}
	}
	if (o.only_syntax)
	{
		parser::Parser p;
		p.init(&pp);
		parser_frontend::FrontendHandler handler;
		handler.bind(&p);
		tree::Tree? parsed = p.parse();
		tree::Tree result;
		if (catch f = parsed)
		{
			p.free();
			if (f == compilation::FATAL_ERROR)
			{
				print_diagnostics_stats(d);
				return 1;
			}
			probe_error("parser stopped: %s", f);
			return 2;
		}
		else { result = parsed; }
		if (o.verbose_ast)
		{
			Terminal term = { .writer = io::stdout(), .mode = diagnostics::ColorMode.NO_COLOR };
			if (catch result.dump(term))
			{
				result.free();
				io::eprintfn("fatal error: unable to write AST");
				return 1;
			}
		}
		result.free();
		print_diagnostics_stats(d);
		return d.errors != 0 ? 1 : 0;
	}

	print_diagnostics_stats(d);
	if (o.dependencies)
	{
		DString output;
		output.init(mem);
		defer output.free();
		dep.write(&output);
		if (catch io::write_all(io::stdout(), output.str_view()))
		{
			io::eprintfn("fatal error: unable to write dependency output");
			return 1;
		}
		(void)io::stdout().flush();
		return 0;
	}
	if (catch f = pp.pretty_print_tokens(io::stdout(), dump_mode))
	{
		// Driver: "unable to write result: ..." is a fatal error.
		io::eprintfn("fatal error: unable to write result: %s", f);
		return 1;
	}
	(void)io::stdout().flush();
	return 0;
}

fn int main(String[] args)
{
	Diagnostics d;
	d.init_writer(io::stderr(), NO_COLOR);
	Compilation comp;
	comp.init(mem, null, &d);
	comp.pragmas.add("GCC", gcc::make_handler(mem));
	comp.pragmas.add("once", once::handler(mem));
	comp.pragmas.add("message", message::handler());
	if (try epoch = env::get_var(mem, "SOURCE_DATE_EPOCH"))
	{
		comp.environment.has_source_date_epoch = true;
		comp.environment.source_date_epoch = epoch;
	}
	long fixed_seconds = 0;
	comp.clock = compilation::fixed_clock(&fixed_seconds);
	int status = run(args, &comp, &d);
	(void)io::stderr().flush();
	comp.free();
	d.free();
	return status;
}

// ---------------------------------------------------------------------------
