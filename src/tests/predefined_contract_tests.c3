// Tests for the plan 14 stage-0 contract code that is implemented (not
// stubbed): MacroWriter and its define helpers, code_gen_options, the
// Compilation clock/environment defaults, attribute_normalize and the new
// target::Feature entries. Expected values are source-derived from
// Compilation.zig, CodeGenOptions.zig and Attribute.zig; no Zig executable
// was run.
module predefined_contract_tests;
import aro::predefined_macros, aro::preprocessor, aro::compilation, aro::code_gen_options, aro::target;
import std::core::mem::allocators;

macro check(left, right)
{
	test::eq((long)left, (long)right);
}

fn void macro_writer_helpers() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		MacroWriter w;
		w.init(&ta);
		w.define("__x86_64__");
		w.define_std("linux", true);
		w.define_std("unix", false);
		w.define_bool("TARGET_OS_WIN32", false);
		w.define_bool("TARGET_OS_LINUX", true);
		w.define_value("__seg_gs", "__attribute__((address_space(256)))");
		w.define_int("__FreeBSD__", 14);
		w.printf("#define __%s_MIN_EXP__ (%d)\n", "FLT", -125);
		w.write("#define __Aro__\n");
		w.write_byte('\n');
		String expected = "#define __x86_64__ 1\n"
			"#define linux 1\n#define __linux 1\n#define __linux__ 1\n"
			"#define __unix 1\n#define __unix__ 1\n"
			"#define TARGET_OS_WIN32 0\n#define TARGET_OS_LINUX 1\n"
			"#define __seg_gs __attribute__((address_space(256)))\n"
			"#define __FreeBSD__ 14\n"
			"#define __FLT_MIN_EXP__ (-125)\n"
			"#define __Aro__\n\n";
		test::eq(w.written(), expected);
		check(w.len(), expected.len);

		char[] owned = w.to_owned_buffer(&ta);
		check(owned.len, expected.len);
		check(owned.ptr[owned.len], 0);
		test::eq((String)owned, expected);
		alloc::free(&ta, owned.ptr);
		w.free();
	}
	check(ta.allocation_count(), 0);
}

fn void code_gen_options_defaults() @test
{
	CodeGenOptions o = code_gen_options::DEFAULT;
	check(o.pic_level.value, 0);
	test::eq(o.optimization_level.has_any_optimizations(), false);
	test::eq(OptimizationLevel.S.is_size_optimized(), true);
	test::eq(OptimizationLevel.Z.is_size_optimized(), true);
	test::eq(OptimizationLevel.FAST.is_size_optimized(), false);
	test::eq(OptimizationLevel.G.has_any_optimizations(), true);
	test::eq(code_gen_options::optimization_level_from_string("fast")!!, OptimizationLevel.FAST);
	test::eq(@ok(code_gen_options::optimization_level_from_string("4")), false);
	check(PicLevel.TWO.value, 2);
	test::eq(code_gen_options::code_model_from_name("kernel")!!, CodeModel.KERNEL);
	test::eq(@ok(code_gen_options::code_model_from_name("huge")), false);
	test::eq(CodeModel.DEFAULT.macro_name(), "small");
	test::eq(CodeModel.MEDANY.macro_name(), "medany");
}

fn void compilation_defaults_and_clock() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Compilation comp;
		comp.init(&ta);
		test::eq(comp.environment.has_source_date_epoch, false);
		test::eq(comp.cmodel, CodeModel.DEFAULT);
		test::eq(comp.code_gen_options.optimization_level, OptimizationLevel.O0);
		// The default clock is the host clock: some time after 2020-01-01.
		test::eq(comp.now_seconds()!! > 1577836800, true);
		long fixed = 1700000000;
		comp.clock = compilation::fixed_clock(&fixed);
		check(comp.now_seconds()!!, 1700000000);
		comp.free();
	}
	check(ta.allocation_count(), 0);
	check(compilation::MAX_SOURCE_EPOCH_TIMESTAMP, 253402300799);
}

fn void normalize_attribute_names() @test
{
	test::eq(preprocessor::attribute_normalize("__noreturn__"), "noreturn");
	test::eq(preprocessor::attribute_normalize("____"), "");
	test::eq(preprocessor::attribute_normalize("__a_"), "__a_");
	test::eq(preprocessor::attribute_normalize("___"), "___");
	test::eq(preprocessor::attribute_normalize("deprecated"), "deprecated");
	check(preprocessor::HAS_BUILTIN_SPECIAL_CASES.len, 6);
}

fn void provider_and_features() @test
{
	BuiltinProvider p = preprocessor::BUILTINS;
	test::eq(p.ctx == null, true);
	// New feature entries parse by their Zig names in their family.
	test::eq(target::parse_feature_name(X86_64, "avx512vbmi")!!, Feature.X86_AVX512VBMI);
	test::eq(target::parse_feature_name(AARCH64, "sme2")!!, Feature.AARCH64_SME2);
	test::eq(target::parse_feature_name(WASM32, "tail_call")!!, Feature.WASM_TAIL_CALL);
	// Every Feature fits in FeatureSet.
	test::eq((usz)Feature::len <= target::FEATURE_WORDS * 64, true);
	// wasm features are contiguous and in Zig declaration (alphabetical) order.
	String prev = "";
	usz wasm_count;
	foreach (f : Feature::values)
	{
		if (f.family != WASM) continue;
		test::eq(prev.compare_to(f.name) < 0, true);
		prev = f.name;
		wasm_count++;
	}
	check(wasm_count, 18);
}
