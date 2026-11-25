// Focused contract tests for the C3 driver command-line parser and policy.
// These tests only parse arguments and resolve synthetic target triples; they
// do not read files, launch subprocesses, or invoke a compiler backend.
module driver_options_tests;
import aro::bigint;
import aro::frontend::c::driver;
import aro::frontend::c::driver_options;
import aro::target;
import aro::code_gen_options;
import aro::frontend::c::compilation;
import aro::frontend::c::diagnostics;
import aro::frontend::c::lang_opts;
import aro::toolchain;
import aro::frontend::c::driver_arguments;
import std::collections::list;
import std::core::mem::allocators;
import std::collections::maybe;

macro check(left, right)
{
	$if $defined((long)left):
		test::eq((long)left, (long)right);
	$else
		assert(left == right, "expected values to match");
	$endif
}

fn void parse_options(DriverOptions* opts, String[] args)
{
	driver::ArgumentResult result = driver::parse_args(opts, args)!!;
	check(result.action, driver_options::ParseAction.CONTINUE);
}

fn void macro_options_and_inputs_are_preserved() @test
{
	DriverOptions opts;
	opts.init(mem);
	defer opts.free();
	parse_options(&opts, {
		"aro", "-D", "FEATURE=1", "-UFEATURE", "-DSECOND", "-Iinc",
		"first.c", "extra.o", "second.c",
	});
	check(opts.defines.len(), 2);
	check(opts.defines.get(0), "FEATURE=1");
	check(opts.defines.get(1), "SECOND");
	check(opts.undefs.len(), 1);
	check(opts.undefs.get(0), "FEATURE");
	check(opts.macro_effects.len(), 3);
	check(opts.macro_effects.get(0).kind, driver_options::ParseEffectKind.DEFINE);
	check(opts.macro_effects.get(0).value, "FEATURE=1");
	check(opts.macro_effects.get(1).kind, driver_options::ParseEffectKind.UNDEFINE);
	check(opts.macro_effects.get(1).value, "FEATURE");
	check(opts.macro_effects.get(2).kind, driver_options::ParseEffectKind.DEFINE);
	check(opts.macro_effects.get(2).value, "SECOND");
	check(opts.includes.len(), 1);
	check(opts.includes.get(0).path, "inc");
	check(opts.inputs.len(), 2);
	check(opts.inputs.get(0), "first.c");
	check(opts.inputs.get(1), "second.c");
	check(opts.link_objects.len(), 1);
	check(opts.link_objects.get(0), "extra.o");
}

fn void linker_search_paths_and_libraries_accept_attached_and_separate_values() @test
{
	DriverOptions opts;
	opts.init(mem);
	defer opts.free();
	parse_options(&opts, {
		"aro", "first.c", "-Lattached-dir", "-lattached", "second.c",
		"-L", "separate-dir", "-l", "separate", "third.c",
	});
	check(opts.lib_dirs.len(), 2);
	check(opts.lib_dirs.get(0), "attached-dir");
	check(opts.lib_dirs.get(1), "separate-dir");
	check(opts.link_objects.len(), 2);
	check(opts.link_objects.get(0), "-lattached");
	check(opts.link_objects.get(1), "-lseparate");
	check(opts.inputs.len(), 3);
	check(opts.inputs.get(0), "first.c");
	check(opts.inputs.get(1), "second.c");
	check(opts.inputs.get(2), "third.c");
	check(opts.input_link_slots.len(), 3);
	check(opts.input_link_slots.get(0), 0);
	check(opts.input_link_slots.get(1), 1);
	check(opts.input_link_slots.get(2), 2);
}

fn void archives_and_shared_libraries_are_link_inputs_but_similar_sources_are_not() @test
{
	DriverOptions opts;
	opts.init(mem);
	defer opts.free();
	parse_options(&opts, {
		"aro", "first.c", "libstatic.a", "second.c", "libshared.so",
		"third.c", "libversion.so.1.2", "foo.so.c", "x.so.abc",
	});
	check(opts.link_objects.len(), 3);
	check(opts.link_objects.get(0), "libstatic.a");
	check(opts.link_objects.get(1), "libshared.so");
	check(opts.link_objects.get(2), "libversion.so.1.2");
	check(opts.inputs.len(), 5);
	check(opts.inputs.get(0), "first.c");
	check(opts.inputs.get(1), "second.c");
	check(opts.inputs.get(2), "third.c");
	check(opts.inputs.get(3), "foo.so.c");
	check(opts.inputs.get(4), "x.so.abc");
	check(opts.input_link_slots.len(), 5);
	check(opts.input_link_slots.get(0), 0);
	check(opts.input_link_slots.get(1), 1);
	check(opts.input_link_slots.get(2), 2);
	check(opts.input_link_slots.get(3), 3);
	check(opts.input_link_slots.get(4), 3);
}

fn void x_language_applies_to_following_inputs() @test
{
	DriverOptions opts;
	opts.init(mem);
	defer opts.free();
	// `-x c` makes even an object-looking name a C input; `-x none` restores
	// extension-based classification. `-` is stdin either way.
	parse_options(&opts, { "aro", "a.o", "-x", "c", "-", "b.o", "-xnone", "c.o" });
	check(opts.inputs.len(), 2);
	check(opts.inputs.get(0), "-");
	check(opts.inputs.get(1), "b.o");
	check(opts.link_objects.len(), 2);
	check(opts.link_objects.get(0), "a.o");
	check(opts.link_objects.get(1), "c.o");

	DriverOptions bad;
	bad.init(mem);
	defer bad.free();
	assert(@catch(driver::parse_args(&bad, { "aro", "-x", "fortran", "a.f" })) == driver::INVALID_ARGUMENT);
}

fn void missing_linker_search_path_and_library_values_are_rejected() @test
{
	DriverOptions missing_search_path;
	missing_search_path.init(mem);
	defer missing_search_path.free();
	assert(@catch(driver::parse_args(&missing_search_path, { "aro", "-L" })) == driver::MISSING_ARGUMENT);

	DriverOptions missing_library;
	missing_library.init(mem);
	defer missing_library.free();
	assert(@catch(driver::parse_args(&missing_library, { "aro", "-l" })) == driver::MISSING_ARGUMENT);
}

fn void merged_link_inputs_follow_user_order_and_source_slots() @test
{
	String[] user_inputs = { "before.o", "-lmiddle", "after.o" };
	usz[] source_slots = { 1, 2, 2 };
	String[] compiled_objects = { "first.o", "second.o", "third.o", "fourth.o" };
	usz[] translation_unit_ends = { 1, 3, 4 };

	List{String} merged;
	merged.init(mem);
	defer merged.free();
	driver::merge_link_inputs(user_inputs, source_slots, compiled_objects,
		translation_unit_ends, false, &merged);
	check(merged.len(), 7);
	check(merged.get(0), "before.o");
	check(merged.get(1), "first.o");
	check(merged.get(2), "-lmiddle");
	check(merged.get(3), "second.o");
	check(merged.get(4), "third.o");
	check(merged.get(5), "fourth.o");
	check(merged.get(6), "after.o");

	List{String} whole_program_merged;
	whole_program_merged.init(mem);
	defer whole_program_merged.free();
	driver::merge_link_inputs(user_inputs, source_slots, compiled_objects,
		translation_unit_ends, true, &whole_program_merged);
	check(whole_program_merged.len(), 7);
	check(whole_program_merged.get(0), "before.o");
	check(whole_program_merged.get(1), "first.o");
	check(whole_program_merged.get(2), "second.o");
	check(whole_program_merged.get(3), "third.o");
	check(whole_program_merged.get(4), "fourth.o");
	check(whole_program_merged.get(5), "-lmiddle");
	check(whole_program_merged.get(6), "after.o");
}

fn void attached_and_separate_option_arguments_are_parsed() @test
{
	DriverOptions opts;
	opts.init(mem);
	defer opts.free();
	parse_options(&opts, {
		"aro", "-DATTACHED=1", "-D", "SEPARATE=2", "-UATTACHED",
		"-U", "SEPARATE", "-Iinc", "-I", "more-inc", "-target",
		"x86_64-linux-gnu", "-mcpu=x86-64", "-std", "c17", "-o",
		"output.o", "source.c",
	});
	check(opts.defines.len(), 2);
	check(opts.defines.get(0), "ATTACHED=1");
	check(opts.defines.get(1), "SEPARATE=2");
	check(opts.undefs.len(), 2);
	check(opts.undefs.get(0), "ATTACHED");
	check(opts.undefs.get(1), "SEPARATE");
	check(opts.includes.len(), 2);
	check(opts.includes.get(0).path, "inc");
	check(opts.includes.get(1).path, "more-inc");
	check(opts.target_triple.value, "x86_64-linux-gnu");
	check(opts.cpu.value, "x86-64");
	check(opts.standard.value, "c17");
	check(opts.output_name.value, "output.o");
}

fn void optimization_and_target_options_use_last_value() @test
{
	DriverOptions opts;
	opts.init(mem);
	defer opts.free();
	parse_options(&opts, {
		"aro", "-O3", "-O0", "-g", "-mcmodel=large", "-mcpu", "x86-64",
		"--target=x86_64-linux-gnu", "-std=c11", "input.c",
	});
	check(opts.optimization.has_value, true);
	check(opts.optimization.value, "0");
	check(opts.debug_format.has_value, true);
	check(opts.debug_format.value, driver_options::DebugFormatRequest.DWARF32);
	check(opts.code_model.has_value, true);
	check(opts.code_model.value, "large");
	check(opts.cpu.has_value, true);
	check(opts.cpu.value, "x86-64");
	check(opts.target_triple.has_value, true);
	check(opts.target_triple.value, "x86_64-linux-gnu");
	check(opts.standard.has_value, true);
	check(opts.standard.value, "c11");
	check(opts.inputs.len(), 1);
	check(code_gen_options::optimization_level_from_string(opts.optimization.value)!!, code_gen_options::OptimizationLevel.O0);
}

fn void optimization_and_code_model_enum_names_are_supported() @test
{
	check(code_gen_options::optimization_level_from_string("fast")!!, code_gen_options::OptimizationLevel.FAST);
	check(code_gen_options::optimization_level_from_string("z")!!, code_gen_options::OptimizationLevel.Z);
	check(code_gen_options::code_model_from_name("large")!!, code_gen_options::CodeModel.LARGE);
	check(code_gen_options::code_model_from_name("medany")!!, code_gen_options::CodeModel.MEDANY);
	assert(@catch(code_gen_options::optimization_level_from_string("9")) == code_gen_options::UNKNOWN_OPTIMIZATION_LEVEL);
	assert(@catch(code_gen_options::code_model_from_name("huge")) == code_gen_options::UNKNOWN_CODE_MODEL);
}

fn void verbose_ir_does_not_enable_hidden_ir_verification() @test
{
	DriverOptions dump_only;
	dump_only.init(mem);
	defer dump_only.free();
	parse_options(&dump_only, { "aro", "--verbose-ir", "source.c" });
	check(dump_only.verbose_ir, true);
	check(dump_only.verify_ir, false);

	DriverOptions verify_only;
	verify_only.init(mem);
	defer verify_only.free();
	parse_options(&verify_only, { "aro", "--verify-ir", "source.c" });
	check(verify_only.verify_ir, true);
	check(verify_only.verbose_ir, false);
}

fn void codegen_todo_report_flag_is_recorded() @test
{
	DriverOptions opts;
	opts.init(mem);
	defer opts.free();
	check(opts.codegen_todo_report, false);
	parse_options(&opts, { "aro", "--codegen-todo-report", "source.c" });
	check(opts.codegen_todo_report, true);
}

fn void debug_format_enum_contract_is_available() @test
{
	CodeGenOptions options = code_gen_options::DEFAULT;
	check(options.debug.kind, code_gen_options::DebugKind.STRIP);
	options.debug = { .kind = code_gen_options::DebugKind.DWARF, .dwarf = code_gen_options::DwarfFormat.FORMAT32 };
	check(options.debug.kind, code_gen_options::DebugKind.DWARF);
	check(options.debug.dwarf, code_gen_options::DwarfFormat.FORMAT32);
}

fn void pic_request_order_and_link_modes_are_recorded() @test
{
	DriverOptions opts;
	opts.init(mem);
	defer opts.free();
	parse_options(&opts, {
		"aro", "-fPIC", "-fpie", "-fno-pic", "-pie", "-static",
		"-shared", "input.c",
	});
	check(opts.pic, driver_options::PicRequest.NO_PIC);
	check(opts.pie.get()!!, true);
	check(opts.static_link, true);
	check(opts.shared, true);
}

fn void verbose_linker_arguments_option_is_recorded() @test
{
	DriverOptions opts;
	opts.init(mem);
	defer opts.free();
	parse_options(&opts, { "aro", "--verbose-linker-args", "source.c" });
	check(opts.verbose_linker_args, true);
}

fn void integrated_assembler_options_follow_argument_order() @test
{
	DriverOptions opts;
	opts.init(mem);
	defer opts.free();
	check(opts.integrated_as.value, false);
	check(opts.integrated_as.has_value, false);

	parse_options(&opts, { "aro", "-fintegrated-as", "source.c" });
	check(opts.integrated_as.value, true);
	check(opts.integrated_as.has_value, true);
	parse_options(&opts, { "aro", "-fno-integrated-as", "source.c" });
	check(opts.integrated_as.value, false);

	parse_options(&opts, { "aro", "-fno-integrated-as", "-fintegrated-as", "source.c" });
	check(opts.integrated_as.value, true);
	parse_options(&opts, { "aro", "-fintegrated-as", "-fno-integrated-as", "source.c" });
	check(opts.integrated_as.value, false);
}

fn void pic_pie_policy_tracks_target_and_explicit_requests() @test
{
	DriverOptions opts;
	opts.init(mem);
	defer opts.free();
	parse_options(&opts, { "aro", "--target=x86_64-linux-gnu", "input.c" });
	Target linux = driver::parse_target(&opts)!!;
	driver::PicPolicy defaults = driver::pic_policy(&opts, linux)!!;
	check(defaults.level, code_gen_options::PicLevel.TWO);
	check(defaults.is_pie, true);

	parse_options(&opts, { "aro", "-fno-pie", "input.c" });
	driver::PicPolicy disabled = driver::pic_policy(&opts, linux)!!;
	check(disabled.level, code_gen_options::PicLevel.NONE);
	check(disabled.is_pie, false);

	parse_options(&opts, { "aro", "-fPIE", "input.c" });
	driver::PicPolicy large_pie = driver::pic_policy(&opts, linux)!!;
	check(large_pie.level, code_gen_options::PicLevel.TWO);
	check(large_pie.is_pie, true);

	parse_options(&opts, { "aro", "--target=x86_64-apple-macosx", "input.c" });
	Target darwin = driver::parse_target(&opts)!!;
	driver::PicPolicy darwin_defaults = driver::pic_policy(&opts, darwin)!!;
	check(darwin_defaults.level, code_gen_options::PicLevel.TWO);
	check(darwin_defaults.is_pie, false);
	parse_options(&opts, { "aro", "-static", "input.c" });
	driver::PicPolicy darwin_static = driver::pic_policy(&opts, darwin)!!;
	check(darwin_static.level, code_gen_options::PicLevel.NONE);
	check(darwin_static.is_pie, false);
}

fn void driver_flag_enums_and_linker_state_are_applied() @test
{
	DriverOptions opts;
	opts.init(mem);
	defer opts.free();
	parse_options(&opts, {
		"aro", "--emulate=msvc", "--target=x86_64-linux-gnu",
		"--emulate=msvc", "-fshort-enums", "-fno-short-enums",
		"-fdollars-in-identifiers", "-fno-dollars-in-identifiers",
		"-fdigraphs", "-fno-digraphs", "-fgnu-inline-asm", "-fno-gnu-inline-asm",
		"-funsigned-char", "-ffp-eval-method=extended", "-fno-declspec",
		"-fno-ms-extensions", "-fexperimental-bounds-safety", "-fchar8_t",
		"-fnative-half-type", "-fnative-half-arguments-and-returns", "-fno-blocks",
		"-pthread", "-fvisibility=hidden",
		"-fgnuc-version=12.3.4", "-fmacro-backtrace-limit=0",
		"--rtlib=compiler-rt", "--unwindlib=libunwind", "-fuse-ld=bfd",
		"--ld-path=/usr/bin/ld", "-shared-libgcc", "-static-pie", "-rdynamic", "-s",
		"-r", "source.c",
	});
	check(opts.emulate.value, target::Compiler.MSVC);
	check(opts.emulate.has_value, true);
	check(opts.short_enums.value, false);
	check(opts.dollars_in_identifiers.value, false);
	check(opts.digraphs.value, false);
	check(opts.gnu_asm.value, false);
	check(opts.char_signedness.value, bigint::Signedness.UNSIGNED);
	check(opts.fp_eval_method.value, target::FPEvalMethod.EXTENDED);
	check(opts.bounds_safety.value, lang_opts::BoundsSafety.CLANG);
	check(opts.char8_t_override.value, true);
	check(opts.visibility.value, lang_opts::Visibility.HIDDEN);
	check(opts.use_native_half_type, true);
	check(opts.allow_half_args_returns, true);
	check(opts.blocks.has_value, true);
	check(opts.blocks.value, false);
	check(opts.pthread, true);
	check(opts.gnuc_version.value, "12.3.4");
	check(opts.macro_backtrace_limit.value, uint::max);
	check(opts.use_linker.has_value, true);
	check(opts.use_linker.get()!!, "bfd");
	check(opts.linker_path.get()!!, "/usr/bin/ld");
	check(opts.rtlib.get()!!, "compiler-rt");
	check(opts.unwindlib.get()!!, "libunwind");

	Diagnostics d;
	d.init_list(mem);
	defer d.free();
	Compilation comp;
	comp.init(mem, null, &d);
	defer comp.free();
	toolchain::Options tc_opts = {};
	driver::apply_options(&opts, &comp, &tc_opts, &d)!!;
	check(comp.langopts.emulate, target::Compiler.MSVC);
	check(comp.langopts.short_enums, false);
	check(comp.langopts.dollars_in_identifiers, false);
	check(comp.langopts.digraphs.get()!!, false);
	check(comp.langopts.gnu_asm, false);
	check(comp.langopts.bounds_safety, lang_opts::BoundsSafety.CLANG);
	check(comp.langopts.char8_t_override.get()!!, true);
	check(comp.langopts.default_symbol_visibility, lang_opts::Visibility.HIDDEN);
	check(comp.langopts.use_native_half_type, true);
	check(comp.langopts.allow_half_args_and_returns, true);
	check(comp.langopts.blocks, false);
	check(comp.langopts.pthread, true);
	check(comp.langopts.ms_extensions, false);
	check(comp.langopts.declspec_attrs, false);
	check(comp.langopts.has_char_signedness_override, true);
	check(comp.langopts.char_signedness_override, bigint::Signedness.UNSIGNED);
	check(comp.langopts.has_fp_eval_method, true);
	check(comp.langopts.fp_eval_method, target::FPEvalMethod.EXTENDED);
	check(comp.langopts.has_gnuc_version, true);
	check(comp.langopts.gnuc_version, 120304);
	check(d.macro_backtrace_limit, uint::max);
	check(tc_opts.shared_libgcc, true);
	check(tc_opts.static_pie, true);
	check(tc_opts.rdynamic, true);
	check(tc_opts.strip, true);
	check(tc_opts.relocatable, true);
	check(tc_opts.use_linker.has_value, true);
	check(tc_opts.use_linker.get()!!, "bfd");
	check(tc_opts.linker_path.has_value, true);
	check(tc_opts.linker_path.get()!!, "/usr/bin/ld");
	check(tc_opts.rtlib.has_value, true);
	check(tc_opts.rtlib.get()!!, "compiler-rt");
	check(tc_opts.unwindlib.has_value, true);
	check(tc_opts.unwindlib.get()!!, "libunwind");
}

fn void target_selection_resets_compiler_emulation() @test
{
	DriverOptions opts;
	opts.init(mem);
	defer opts.free();
	parse_options(&opts, { "aro", "--emulate=gcc", "--target=x86_64-linux-gnu", "input.c" });
	check(opts.emulate.has_value, false);
}

fn void warning_switches_keep_argv_order_and_exact_unknown_text() @test
{
	DriverOptions opts;
	opts.init(mem);
	defer opts.free();
	parse_options(&opts, {
		"aro", "-Wdeprecated-declarations", "-Wno-deprecated-declarations",
		"-Werror=deprecated-declarations", "-Wno-error=deprecated-declarations", "input.c",
	});
	check(opts.warning_policies.len(), 4);
	check(opts.warning_policies.get(0).name, "deprecated-declarations");
	check(opts.warning_policies.get(0).mode, driver_options::WarningMode.WARNING);
	check(opts.warning_policies.get(1).mode, driver_options::WarningMode.OFF);
	check(opts.warning_policies.get(2).mode, driver_options::WarningMode.ERROR);
	check(opts.warning_policies.get(3).mode, driver_options::WarningMode.WARNING);

	Diagnostics d;
	d.init_list(mem);
	defer d.free();
	driver::apply_diagnostic_options({ "aro", "-Wdeprecated-declarations",
		"-Werror=deprecated-declarations", "-Wno-error=deprecated-declarations" }, &d)!!;
	check(d.state.options.get(diagnostics::Option.DEPRECATED_DECLARATIONS)!!, diagnostics::MessageKind.WARNING);
	driver::apply_diagnostic_options({ "aro", "-Werror", "-Wno-error",
		"-pedantic-errors", "-pedantic" }, &d)!!;
	check(d.state.error_warnings, false);
	check(d.state.extensions, diagnostics::MessageKind.WARNING);
	driver::apply_diagnostic_options({ "aro", "-W" }, &d)!!;
	check(d.messages.len(), 1);
	check(d.messages[0].text, "unknown warning ''");
	check(d.messages[0].opt, diagnostics::Option.UNKNOWN_WARNING_OPTION);
}

fn void exact_driver_diagnostics_are_collected() @test
{
	DriverOptions opts;
	opts.init(mem);
	defer opts.free();
	Diagnostics d;
	d.init_list(mem);
	defer d.free();
	fault fatal = @catch(driver::parse_args(&opts, { "aro", "-fgnuc-version=bad", "input.c" }, &d));
	assert(fatal == compilation::FATAL_ERROR, "invalid -fgnuc-version should return FATAL_ERROR");
	check(d.messages.len(), 1);
	check(d.messages[0].kind, diagnostics::MessageKind.FATAL_ERROR);
	check(d.messages[0].text, "invalid value 'bad' in '-fgnuc-version=bad'");

	DriverOptions bad_fp;
	bad_fp.init(mem);
	defer bad_fp.free();
	driver::parse_args(&bad_fp, { "aro", "-ffp-eval-method=fast" }, &d)!!;
	check(d.messages[1].kind, diagnostics::MessageKind.ERROR);
	check(d.messages[1].text, "unsupported argument 'fast' to option '-ffp-eval-method='; expected 'source', 'double', or 'extended'");
}

fn void early_output_text_matches_the_driver_contract() @test
{
	String usage = driver::usage_text(mem, "aro");
	defer alloc::free(mem, usage.ptr);
	assert(usage.starts_with("Usage aro: [options] file..\n\nGeneral options:\n"));
	assert(usage.contains("  -fms-extensions         Enable support for Microsoft extensions\n"));
	assert(usage.ends_with("\n\n\n"));
	String version = driver::version_text(mem);
	defer alloc::free(mem, version.ptr);
	check(aro::VERSION, "0.1.0-dev");
	check(version, "0.1.0-dev\n");
}

fn void pic_policy_reports_target_conflicts_and_linker_defaults() @test
{
	DriverOptions windows_opts;
	windows_opts.init(mem);
	defer windows_opts.free();
	parse_options(&windows_opts, { "aro", "--target=x86_64-windows-msvc", "-fpic" });
	Target windows = driver::parse_target(&windows_opts)!!;
	Diagnostics d;
	d.init_list(mem);
	defer d.free();
	driver::PicPolicy windows_pic = driver::pic_policy(&windows_opts, windows, &d)!!;
	check(windows_pic.level, code_gen_options::PicLevel.TWO);
	check(d.messages.len(), 1);
	check(d.messages[0].text, "unsupported option '-fpic' for target 'x86_64-windows-msvc'");

	DriverOptions conflict_opts;
	conflict_opts.init(mem);
	defer conflict_opts.free();
	parse_options(&conflict_opts, { "aro", "--target=arm-linux-gnueabi", "-fropi", "-fpic" });
	Target arm = driver::parse_target(&conflict_opts)!!;
	Diagnostics conflict_diagnostics;
	conflict_diagnostics.init_list(mem);
	defer conflict_diagnostics.free();
	driver::pic_policy(&conflict_opts, arm, &conflict_diagnostics)!!;
	check(conflict_diagnostics.messages.len(), 1);
	check(conflict_diagnostics.messages[0].text, "embedded and GOT-based position independence are incompatible");

	DriverOptions linker_opts;
	linker_opts.init(mem);
	defer linker_opts.free();
	parse_options(&linker_opts, { "aro", "--target=x86_64-windows-msvc", "-fuse-ld=bfd" });
	Target linker_target = driver::parse_target(&linker_opts)!!;
	check(driver::pic_policy(&linker_opts, linker_target)!!.level, code_gen_options::PicLevel.TWO);
	parse_options(&linker_opts, { "aro", "-fuse-ld=lld" });
	check(driver::pic_policy(&linker_opts, linker_target)!!.level, code_gen_options::PicLevel.TWO);
}

fn void apple_kernel_pic_override_respects_minimum_os_versions() @test
{
	DriverOptions old_ios_opts;
	old_ios_opts.init(mem);
	defer old_ios_opts.free();
	parse_options(&old_ios_opts, { "aro", "--target=arm64-apple-ios5.0", "-mkernel" });
	Target old_ios = driver::parse_target(&old_ios_opts)!!;
	check(driver::pic_policy(&old_ios_opts, old_ios)!!.level, code_gen_options::PicLevel.ONE);

	DriverOptions new_ios_opts;
	new_ios_opts.init(mem);
	defer new_ios_opts.free();
	parse_options(&new_ios_opts, { "aro", "--target=arm64-apple-ios6.0", "-mkernel" });
	Target new_ios = driver::parse_target(&new_ios_opts)!!;
	check(driver::pic_policy(&new_ios_opts, new_ios)!!.level, code_gen_options::PicLevel.NONE);
}

fn void macro_backtrace_limit_uses_zig_unsigned_integer_rules() @test
{
	DriverOptions separated;
	separated.init(mem);
	defer separated.free();
	parse_options(&separated, { "aro", "-fmacro-backtrace-limit=+1_0" });
	check(separated.macro_backtrace_limit.value, 10);

	DriverOptions negative_zero;
	negative_zero.init(mem);
	defer negative_zero.free();
	parse_options(&negative_zero, { "aro", "-fmacro-backtrace-limit=-0" });
	check(negative_zero.macro_backtrace_limit.value, uint::max);
}

fn void help_and_version_are_parse_actions_not_backend_runs() @test
{
	DriverOptions help_opts;
	help_opts.init(mem);
	defer help_opts.free();
	driver::ArgumentResult help = driver::parse_args(&help_opts, { "aro", "--help" })!!;
	check(help.action, driver_options::ParseAction.HELP);
	check(help_opts.action, driver_options::ParseAction.HELP);

	DriverOptions version_opts;
	version_opts.init(mem);
	defer version_opts.free();
	driver::ArgumentResult version = driver::parse_args(&version_opts, { "aro", "--version" })!!;
	check(version.action, driver_options::ParseAction.VERSION);
	check(version_opts.action, driver_options::ParseAction.VERSION);
}

fn void missing_values_and_bad_optimization_are_rejected() @test
{
	DriverOptions missing;
	missing.init(mem);
	defer missing.free();
	assert(@catch(driver::parse_args(&missing, { "aro", "-D" })) == driver::MISSING_ARGUMENT);

	DriverOptions bad_level;
	bad_level.init(mem);
	defer bad_level.free();
	assert(@catch(driver::parse_args(&bad_level, { "aro", "-O9" })) == driver::INVALID_ARGUMENT);

	DriverOptions missing_target;
	missing_target.init(mem);
	defer missing_target.free();
	assert(@catch(driver::parse_args(&missing_target, { "aro", "-target" })) == driver::MISSING_ARGUMENT);

	DriverOptions unknown;
	unknown.init(mem);
	defer unknown.free();
	assert(@catch(driver::parse_args(&unknown, { "aro", "-unknown" })) == driver::INVALID_ARGUMENT);
}

fn void recognized_option_prefixes_are_options_and_option_values_may_name_dash_files() @test
{
	DriverOptions opts;
	opts.init(mem);
	defer opts.free();
	parse_options(&opts, { "aro", "-DNAME=1", "-fsyntax-only", "-o", "-output.c", "source.c" });
	check(opts.defines.len(), 1);
	check(opts.only_syntax, true);
	check(opts.output_name.value, "-output.c");
	check(opts.inputs.len(), 1);
	check(opts.inputs.get(0), "source.c");
}

fn void emulated_args(String[] args, List{String}* kept, List{String}* dropped)
{
	kept.init(mem);
	dropped.init(mem);
	driver::filter_emulated_args(args, kept, dropped);
}

fn void driver_arguments_match_spellings_and_kinds() @test
{
	check(driver_arguments::match("-fapple-kext")!!, DriverArgument.APPLE_KEXT);
	check(driver_arguments::match("--compile")!!, DriverArgument.COMPILE);
	check(driver_arguments::match("-c")!!, DriverArgument.COMPILE);
	// Exact spelling beats the joined prefix; otherwise the longest prefix wins.
	check(driver_arguments::match("-fvisibility=hidden")!!, DriverArgument.VISIBILITY_HIDDEN);
	check(driver_arguments::match("-fvisibility=internal")!!, DriverArgument.VISIBILITY_EQ);
	check(driver_arguments::match("-Wno-error=vla")!!, DriverArgument.WNO_ERROR_EQ);
	assert(@catch(driver_arguments::match("-fnot-an-aro-flag")) == driver_arguments::UNKNOWN_ARGUMENT);

	DriverArgument std = driver_arguments::match("-std=c11")!!;
	check(std, DriverArgument.STD_EQ);
	check(std.kind, driver_arguments::ArgKind.EQUALS);
	check(std.joined_value("-std=c11"), "c11");
	check(driver_arguments::match("-std")!!, DriverArgument.STD);
	assert(@catch(driver_arguments::match("-stdc11")) == driver_arguments::UNKNOWN_ARGUMENT);
	check(std.takes_next("-std=c11"), false);
	DriverArgument include_dir = driver_arguments::match("-I")!!;
	check(include_dir.kind, driver_arguments::ArgKind.JOINED_OR_SEPARATE);
	check(include_dir.takes_next("-I"), true);
	check(include_dir.takes_next("-Ifoo"), false);
	check(driver_arguments::match("-o")!!.takes_next("-o"), true);

	Supported blocks = DriverArgument.BLOCKS.supported;
	check(blocks.clang, true);
	check(blocks.gcc, false);
	check(DriverArgument.SYNTAX_ONLY.supported.gcc, true);
	check(DriverArgument.TARGET_EQ.toolchain, true);
	check(DriverArgument.WEVERYTHING.supported.gcc, false);
	check(diagnostics::warning_support("designated-init")!!.clang, false);
	Supported unused = diagnostics::warning_support("unused-variable")!!;
	check(unused.gcc && unused.clang, true);
	check(diagnostics::Option.UNUSED_VARIABLE.supported.gcc, true);
	check(diagnostics::warning_support("gnu")!!.gcc, false);
	check(diagnostics::OptionGroup.GNU.supported.clang, true);
	// Specials and unknown names are not options; filtering goes by the argument.
	assert(@catch(diagnostics::warning_support("everything")) == diagnostics::NOT_FOUND);
	assert(@catch(diagnostics::warning_support("nope")) == diagnostics::NOT_FOUND);
}

fn void emulate_gcc_drops_clang_only_flags_and_warnings() @test
{
	List{String} kept;
	List{String} dropped;
	emulated_args({ "aro", "--target=x86_64-linux-gnu", "--emulate=gcc", "-fblocks", "-fgnuc-version=4",
		"-Weverything", "-Wno-error=gnu", "-nobuiltininc", "-std=c11", "-Wunused-variable", "input.c" }, &kept, &dropped);
	defer { kept.free(); dropped.free(); }
	check(dropped.len(), 4);
	check(dropped[0], "-fblocks");
	check(dropped[1], "-fgnuc-version=4");
	check(dropped[2], "-Weverything");
	check(dropped[3], "-Wno-error=gnu");
	// Driver plumbing (-nobuiltininc, --target=) and shared flags survive.
	check(kept.len(), 7);
	check(kept[1], "--target=x86_64-linux-gnu");
	check(kept[3], "-nobuiltininc");
	check(kept[4], "-std=c11");
	check(kept[6], "input.c");
}

fn void emulated_filter_skips_separate_values() @test
{
	List{String} kept;
	List{String} dropped;
	// `-o -fblocks` names an output file, not a flag; it is kept untouched.
	emulated_args({ "aro", "--emulate=gcc", "-o", "-fblocks", "-include", "-fdeclspec", "input.c" }, &kept, &dropped);
	defer { kept.free(); dropped.free(); }
	check(dropped.len(), 0);
	check(kept.len(), 7);
}

fn void emulate_clang_drops_gcc_only_warnings() @test
{
	List{String} kept;
	List{String} dropped;
	emulated_args({ "aro", "--emulate=clang", "-Wdesignated-init", "-Werror=normalized", "-fblocks", "input.c" },
		&kept, &dropped);
	defer { kept.free(); dropped.free(); }
	check(dropped.len(), 2);
	check(dropped[0], "-Wdesignated-init");
	check(dropped[1], "-Werror=normalized");
	check(kept.len(), 4);
}

fn void implicit_or_reset_emulation_filters_nothing() @test
{
	String[][] cases = {
		{ "aro", "-fblocks", "-Weverything", "input.c" },
		{ "aro", "--emulate=gcc", "--target=x86_64-linux-gnu", "-fblocks", "input.c" },
		{ "aro", "--emulate=gcc", "-target", "x86_64-linux-gnu", "-fblocks", "input.c" },
		{ "aro", "--emulate=msvc", "-fblocks", "-Wdesignated-init", "input.c" },
	};
	foreach (args : cases)
	{
		List{String} kept;
		List{String} dropped;
		emulated_args(args, &kept, &dropped);
		check(dropped.len(), 0);
		check(kept.len(), args.len);
		kept.free();
		dropped.free();
	}
}

fn void emulated_argument_warning_text_and_silencing() @test
{
	String[] kept = { "aro", "--emulate=gcc", "input.c" };
	String[] dropped = { "-fblocks" };
	Diagnostics d;
	d.init_list(mem);
	defer d.free();
	driver::warn_emulated_args(&d, kept, dropped)!!;
	check(d.messages.len(), 1);
	check(d.messages[0].kind, diagnostics::MessageKind.WARNING);
	check(d.messages[0].opt, diagnostics::Option.EMULATED_COMPILER_ARGUMENT);
	check(d.messages[0].text, "argument '-fblocks' is only supported by clang; ignored when emulating gcc");

	Diagnostics quiet;
	quiet.init_list(mem);
	defer quiet.free();
	driver::apply_diagnostic_options({ "aro", "-Wno-emulated-compiler-argument" }, &quiet)!!;
	driver::warn_emulated_args(&quiet, kept, dropped)!!;
	check(quiet.messages.len(), 0);
}

fn void every_driver_argument_has_a_parse_args_handler() @test
{
	foreach (argument : DriverArgument::values)
	{
		foreach (spelling : argument.args)
		{
			DriverOptions opts;
			opts.init(mem);
			Diagnostics d;
			d.init_list(mem);
			// A value for separate/joined forms; parse_args must not reach `unreachable`.
			String form = argument.kind == EQUALS ? string::tformat("%s=value", spelling) : spelling;
			(void)driver::parse_args(&opts, { "aro", form, "value", "input.c" }, &d);
			d.free();
			opts.free();
		}
	}
}
