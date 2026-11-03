// Plan 12.1 def-parser tests: generate_def::parse_def over the 19 real .def
// files (Bazel data, read from the runfiles tree) and over malformed inputs,
// one or more per fault in tools/generate_def_schema.c3.
//
// Expected values are source-derived (no Zig executable was run): counts were
// taken from the .def files themselves (non-comment, non-property trimmed lines
// = names; uncommented `.features` lines; `.header` lines other than `.none`;
// `.language` lines other than `.all_languages`), and sample records were read
// from the cited lines. Total: 13,552 builtins (tools/builtins_schema.md).
module def_parse_tests;
import std::io, std::collections::list, generate_def, aro::builtin_properties;

macro check(left, right)
{
	test::eq((long)left, (long)right);
}

struct DefCounts
{
	BuiltinGroup group;
	uint entries;
	uint features;
	uint headers;
	uint languages;
	String first;
	String last;
}

const DefCounts[] COUNTS = {
	{ AARCH64, 241, 34, 172, 164, "_AddressOfReturnAddress", "__builtin_arm_yield" },
	{ AARCH64_NEON, 36, 36, 0, 0, "__builtin_sve_svdup_neonq_bf16", "__builtin_sve_svset_neonq_u8" },
	{ AMDGCN, 844, 647, 0, 0, "__builtin_amdgcn_add_max_i32", "__builtin_r600_recipsqrt_ieeef" },
	{ ARM, 260, 8, 115, 113, "_BitScanForward", "__yield" },
	{ BPF, 4, 0, 0, 0, "__builtin_btf_type_id", "__builtin_preserve_type_info" },
	{ COMMON, 1503, 0, 448, 193, "__builtin_choose_expr", "__builtin_zos_va_start" },
	{ HEXAGON, 2040, 2040, 0, 0, "__builtin_SI_to_SXTHI_asrh", "__builtin_HEXAGON_prefetch" },
	{ LOONGARCH, 1517, 1503, 0, 0, "__builtin_lasx_cast_128", "__builtin_lsx_vxori_b" },
	{ MIPS, 669, 0, 0, 0, "__builtin_mips_absq_s_ph", "__builtin_msa_xori_b" },
	{ NEON, 1084, 1084, 0, 0, "__builtin_neon___a32_vcvt_bf16_f32", "__builtin_neon_vzipq_v" },
	{ NVPTX, 877, 454, 0, 0, "__bmma_m8n8k128_ld_a_b1", "__syncthreads" },
	{ POWERPC, 545, 417, 0, 0, "__builtin_addf128_round_to_odd", "__builtin_vsx_xxsldwi" },
	{ RISCV, 161, 81, 0, 0, "__builtin_riscv_aes32dsi", "__builtin_riscv_zip_32" },
	{ S390X, 291, 291, 0, 0, "__builtin_non_tx_store", "__builtin_s390_vupllh" },
	{ VE, 1263, 0, 0, 0, "__builtin_ve_vl_andm_MMM", "__builtin_ve_vl_xorm_mmm" },
	{ WASM, 132, 118, 0, 0, "__builtin_wasm_abs_f16x8", "__builtin_wasm_trunc_u_i64_f64" },
	{ X86_64, 165, 149, 10, 10, "_BitScanForward64", "__builtin_ia32_xsaves64" },
	{ X86, 1916, 1858, 41, 31, "_AddressOfReturnAddress", "__builtin_ia32_xtest" },
	{ XCORE, 4, 0, 0, 0, "__builtin_bitrev", "__builtin_setps" },
};

fn String def_path(BuiltinGroup g)
{
	return string::tformat("src/aro/Builtins/%s.def", g.def_name);
}

fn String load_def(BuiltinGroup g)
{
	return (String)file::load(tmem, def_path(g))!!;
}

fn DefFile parse_ok(BuiltinGroup g, String text)
{
	DefDiag diag;
	DefFile? f = generate_def::parse_def(mem, text, g, &diag);
	if (catch err = f)
	{
		io::eprintfn("unexpected %s at line %d: '%s'", err, diag.line, diag.detail);
		unreachable("parse failed");
	}
	return f;
}

<* Parses `text` expecting fault `want` at line `line` with diag detail `detail`. *>
fn void expect_fault(String text, fault want, uint line, String detail, BuiltinGroup g = X86)
{
	DefDiag diag;
	DefFile? f = generate_def::parse_def(mem, text, g, &diag);
	if (try ok = f)
	{
		ok.free();
		io::eprintfn("expected %s, parse succeeded: %s", want, text);
		unreachable("expected a fault");
	}
	fault got = @catch(f);
	if (got != want || diag.line != line || diag.detail != detail)
	{
		io::eprintfn("input: %s\nexpected %s @%d '%s', got %s @%d '%s'", text, want, line, detail, got, diag.line, diag.detail);
		unreachable("wrong fault");
	}
}

fn DefEntry* find(DefFile* f, String name)
{
	foreach (&e : f.entries) if (e.name == name) return e;
	unreachable("entry not found");
}

fn void every_def_file() @test
{
	check(COUNTS.len, BuiltinGroup::len);
	sz total = 0;
	foreach (c : COUNTS)
	{
		@pool()
		{
			DefFile f = parse_ok(c.group, load_def(c.group));
			defer f.free();
			assert(f.group == c.group);
			check(f.entries.len(), c.entries);
			total += f.entries.len();
			uint feats, hdrs, langs;
			foreach (e : f.entries)
			{
				assert(e.record.param_str.len > 0, "%s", e.name);
				if (e.record.features.len) feats++;
				if (e.record.header != Header.NONE) hdrs++;
				if (e.record.language != ALL_LANGUAGES) langs++;
			}
			check(feats, c.features);
			check(hdrs, c.headers);
			check(langs, c.languages);
			assert(f.entries[0].name == c.first, "%s first", c.group);
			assert(f.entries[^1].name == c.last, "%s last", c.group);
		};
	}
	check(total, 13552);
}

fn void common_samples() @test
{
	@pool()
	{
		DefFile f = parse_ok(COMMON, load_def(COMMON));
		defer f.free();
		// common.def:1-6
		DefEntry* e = &f.entries[0];
		check(e.line, 3);
		assert(e.record.param_str == "v.");
		check((uint)e.record.attributes, (uint)builtin_properties::ATTRIBUTES_DEFAULT.with_field(CUSTOM_TYPECHECK, 1));
		// common.def:1094-1096
		e = find(&f, "__builtin_setjmp");
		check(e.line, 1094);
		assert(e.record.param_str == "iv**");
		Attributes want = { .returns_twice = true, .eval_args = true };
		check((uint)e.record.attributes, (uint)want);
		// common.def:1019-1021 (.eval_args = false overrides the default)
		e = find(&f, "__builtin_classify_type");
		want = { .is_const = true, .custom_typecheck = true, .const_evaluable = true };
		check((uint)e.record.attributes, (uint)want);
		// common.def:4467-4471
		e = find(&f, "printf");
		check(e.line, 4467);
		assert(e.record.param_str == "icC*.");
		assert(e.record.header == STDIO);
		assert(e.record.language == ALL_LANGUAGES);
		want = { .lib_function_without_prefix = true, .eval_args = true };
		check((uint)e.record.attributes, (uint)want);
		assert(e.record.features == "");
		// Both spellings of _exit are distinct names.
		find(&f, "_Exit");
		find(&f, "_exit");
	};
}

fn void target_samples() @test
{
	@pool()
	{
		DefFile f = parse_ok(X86, load_def(X86));
		defer f.free();
		// x86.def:190-194
		DefEntry* e = find(&f, "_mm_prefetch");
		check(e.line, 190);
		assert(e.record.param_str == "vcC*i");
		assert(e.record.header == XMMINTRIN);
		Attributes want = { .is_const = true, .eval_args = true };
		check((uint)e.record.attributes, (uint)want);

		DefFile g = parse_ok(X86_64, load_def(X86_64));
		defer g.free();
		// x86_64.def:246-247: all defaults but param_str
		e = find(&g, "__builtin_ia32_readeflags_u64");
		check(e.line, 246);
		assert(e.record.param_str == "UOi");
		assert(e.record.language == ALL_LANGUAGES && e.record.header == Header.NONE && e.record.features == "");
		check((uint)e.record.attributes, (uint)builtin_properties::ATTRIBUTES_DEFAULT);

		DefFile n = parse_ok(NVPTX, load_def(NVPTX));
		defer n.free();
		// nvptx.def:3-5: grouped feature expression is kept raw
		e = &n.entries[0];
		check(e.line, 3);
		assert(e.record.features.starts_with("(sm_75|sm_80|"));
		assert(e.record.features.ends_with("|ptx91|ptx92)"));

		DefFile a = parse_ok(ARM, load_def(ARM));
		defer a.free();
		// arm.def:1087-1090
		e = find(&a, "__dmb");
		check(e.line, 1087);
		assert(e.record.header == ARM_ACLE);
		want = { .is_const = true, .eval_args = true };
		check((uint)e.record.attributes, (uint)want);
	};
}

fn void grammar_forms() @test
{
	String text = "# comment\r\n"
		"\t foo \t\r\n"
		"  .param_str=\"v\"\r"
		".attributes = .{}\n"
		"#  .features = \"x\"\n"
		"\n"
		"bar\n"
		"\t.param_str =\t\"iC*\"\n"
		".language = .c23_lang\n"
		".header = .stdbit\n"
		".features = \"(a|b),c\"\n"
		".attributes = .{ .@\"noreturn\" = true,.pure=true , .const = true, .format_kind = .vprintf, .format_string_position = 31, .eval_args = false, }\n"
		"baz\n"
		".attributes = .{ .format_string_position = 007 }\n"
		".param_str = \"\"";
	DefFile f = parse_ok(X86, text);
	defer f.free();
	check(f.entries.len(), 3);
	DefEntry e = f.entries[0];
	assert(e.name == "foo");
	check(e.line, 2);
	assert(e.record.param_str == "v");
	check((uint)e.record.attributes, (uint)builtin_properties::ATTRIBUTES_DEFAULT);
	e = f.entries[1];
	assert(e.name == "bar");
	check(e.line, 7);
	assert(e.record.param_str == "iC*");
	assert(e.record.language == C23_LANG);
	assert(e.record.header == STDBIT);
	assert(e.record.features == "(a|b),c");
	Attributes want = { .noreturn = true, .pure = true, .is_const = true, .format_kind = VPRINTF, .format_string_position = 31 };
	check((uint)e.record.attributes, (uint)want);
	e = f.entries[2];
	assert(e.name == "baz");
	check(e.line, 13);
	assert(e.record.param_str == "");
	want = { .format_string_position = 7, .eval_args = true };
	check((uint)e.record.attributes, (uint)want);

	// Empty and comment-only input.
	DefFile empty = parse_ok(COMMON, "");
	check(empty.entries.len(), 0);
	empty.free();
	empty = parse_ok(COMMON, "# nothing\n\n   \n");
	check(empty.entries.len(), 0);
	empty.free();
}

fn void syntax_errors() @test
{
	expect_fault("const std = @import(\"std\");\n", generate_def::SYNTAX_ERROR, 1, "const std = @import(\"std\");");
	expect_fault("a\n.param_str = \"v\"\npub const X = 1;\n", generate_def::SYNTAX_ERROR, 3, "pub const X = 1;");
	expect_fault("foo bar\n", generate_def::SYNTAX_ERROR, 1, "foo bar");
	expect_fault("1foo\n", generate_def::SYNTAX_ERROR, 1, "1foo");
	expect_fault("a\n.param_str = \"v\"\n.\n", generate_def::SYNTAX_ERROR, 3, ".");
	expect_fault("a\n.param_str \"v\"\n", generate_def::SYNTAX_ERROR, 2, ".param_str \"v\"");
	expect_fault("a\n.param_str = \"v\n", generate_def::SYNTAX_ERROR, 2, ".param_str = \"v");
	expect_fault("a\n.param_str = \"v\\n\"\n", generate_def::SYNTAX_ERROR, 2, ".param_str = \"v\\n\"");
	expect_fault("a\n.param_str = \"v\" x\n", generate_def::SYNTAX_ERROR, 2, ".param_str = \"v\" x");
	expect_fault("a\n.param_str = \"v\"\n.header = .stdio,\n", generate_def::SYNTAX_ERROR, 3, ".header = .stdio,");
	expect_fault("a\n.param_str = \"v\"\n.header = #stdio\n", generate_def::SYNTAX_ERROR, 3, ".header = #stdio");
	expect_fault("a\n.param_str = \"v\"\n.attributes = .{ .pure = true\n", generate_def::SYNTAX_ERROR, 3, ".attributes = .{ .pure = true");
	expect_fault("a\n.param_str = \"v\"\n.attributes = .{ pure = true }\n", generate_def::SYNTAX_ERROR, 3, ".attributes = .{ pure = true }");
	expect_fault("a\n.param_str = \"v\"\n.attributes = .{ .pure true }\n", generate_def::SYNTAX_ERROR, 3, ".attributes = .{ .pure true }");
	expect_fault("a\n.param_str = \"v\"\n.attributes = .{ .pure = true .noreturn = true }\n", generate_def::SYNTAX_ERROR, 3, ".attributes = .{ .pure = true .noreturn = true }");
	expect_fault("a\n.param_str = \"v\"\n.attributes = .{ .@\"const = true }\n", generate_def::SYNTAX_ERROR, 3, ".attributes = .{ .@\"const = true }");
	expect_fault("a\n.param_str = \"v\"\n.attributes = .{ , }\n", generate_def::SYNTAX_ERROR, 3, ".attributes = .{ , }");
	expect_fault("a\n.param_str = \"v\"\n.attributes = .{ .pure = true } }\n", generate_def::SYNTAX_ERROR, 3, ".attributes = .{ .pure = true } }");
}

fn void orphan_property() @test
{
	expect_fault("# header\n  .param_str = \"v\"\nfoo\n", generate_def::ORPHAN_PROPERTY, 2, ".param_str = \"v\"");
	expect_fault(".bogus\n", generate_def::ORPHAN_PROPERTY, 1, ".bogus");
}

fn void duplicate_name() @test
{
	expect_fault("foo\n.param_str = \"v\"\nbar\n.param_str = \"v\"\n\nfoo\n.param_str = \"i\"\n", generate_def::DUPLICATE_NAME, 6, "foo");
	// Case differs: distinct names (common.def has _Exit and _exit).
	DefFile f = parse_ok(COMMON, "_Exit\n.param_str = \"v\"\n_exit\n.param_str = \"v\"\n");
	check(f.entries.len(), 2);
	f.free();
}

fn void duplicate_property() @test
{
	expect_fault("foo\n.param_str = \"v\"\n.param_str = \"i\"\n", generate_def::DUPLICATE_PROPERTY, 3, "param_str");
	expect_fault("foo\n.param_str = \"v\"\n.header = .stdio\n.header = .stdio\n", generate_def::DUPLICATE_PROPERTY, 4, "header");
	expect_fault("foo\n.param_str = \"v\"\n.attributes = .{}\n.attributes = .{}\n", generate_def::DUPLICATE_PROPERTY, 4, "attributes");
	expect_fault("foo\n.param_str = \"v\"\n.attributes = .{ .pure = true, .pure = false }\n", generate_def::DUPLICATE_PROPERTY, 3, "pure");
	expect_fault("foo\n.param_str = \"v\"\n.attributes = .{ .const = true, .@\"const\" = true }\n", generate_def::DUPLICATE_PROPERTY, 3, "const");
	// The same property on different builtins is fine.
	DefFile f = parse_ok(X86, "a\n.param_str = \"v\"\n.features = \"x\"\nb\n.param_str = \"v\"\n.features = \"x\"\n");
	check(f.entries.len(), 2);
	f.free();
}

fn void unknown_property() @test
{
	expect_fault("foo\n.param_str = \"v\"\n.target_set = .{}\n", generate_def::UNKNOWN_PROPERTY, 3, "target_set");
	expect_fault("foo\n.Param_str = \"v\"\n", generate_def::UNKNOWN_PROPERTY, 2, "Param_str");
}

fn void unknown_value() @test
{
	expect_fault("foo\n.param_str = \"v\"\n.header = .stdio_h\n", generate_def::UNKNOWN_VALUE, 3, "stdio_h");
	expect_fault("foo\n.param_str = \"v\"\n.header = .STDIO\n", generate_def::UNKNOWN_VALUE, 3, "STDIO");
	expect_fault("foo\n.param_str = \"v\"\n.language = .gnu\n", generate_def::UNKNOWN_VALUE, 3, "gnu");
	expect_fault("foo\n.param_str = \"v\"\n.attributes = .{ .is_const = true }\n", generate_def::UNKNOWN_VALUE, 3, "is_const");
	expect_fault("foo\n.param_str = \"v\"\n.attributes = .{ .format_kind = .printk }\n", generate_def::UNKNOWN_VALUE, 3, "printk");
	expect_fault("foo\n.param_str = \"v\"\n.attributes = .{ .format_string_position = 32 }\n", generate_def::UNKNOWN_VALUE, 3, "32");
	expect_fault("foo\n.param_str = \"v\"\n.attributes = .{ .format_string_position = 99999999999999999999 }\n", generate_def::UNKNOWN_VALUE, 3, "99999999999999999999");
	expect_fault("foo\n.param_str = \"v\"\n.attributes = .{ .format_string_position = 3x }\n", generate_def::UNKNOWN_VALUE, 3, "3x");
	expect_fault("foo\n.param_str = \"v\"\n.attributes = .{ .pure = yes }\n", generate_def::UNKNOWN_VALUE, 3, "yes");
	expect_fault("foo\n.param_str = \"v\"\n.attributes = .{ .pure = 1 }\n", generate_def::UNKNOWN_VALUE, 3, "1");
	// Values of the wrong kind.
	expect_fault("foo\n.param_str = .v\n", generate_def::UNKNOWN_VALUE, 2, ".param_str = .v");
	expect_fault("foo\n.param_str = \"v\"\n.header = \"stdio\"\n", generate_def::UNKNOWN_VALUE, 3, ".header = \"stdio\"");
	expect_fault("foo\n.param_str = \"v\"\n.language = all_languages\n", generate_def::UNKNOWN_VALUE, 3, ".language = all_languages");
	expect_fault("foo\n.param_str = \"v\"\n.attributes = .pure\n", generate_def::UNKNOWN_VALUE, 3, ".attributes = .pure");
	expect_fault("foo\n.param_str = \"v\"\n.features = .{}\n", generate_def::UNKNOWN_VALUE, 3, ".features = .{}");
	expect_fault("foo\n.param_str = \"v\"\n.attributes = .{ .pure = .true }\n", generate_def::UNKNOWN_VALUE, 3, ".attributes = .{ .pure = .true }");
	expect_fault("foo\n.param_str = \"v\"\n.attributes = .{ .format_kind = \"printf\" }\n", generate_def::UNKNOWN_VALUE, 3, ".attributes = .{ .format_kind = \"printf\" }");
	expect_fault("foo\n.param_str = \"v\"\n.attributes = .{ .format_string_position = true }\n", generate_def::UNKNOWN_VALUE, 3, "true");
	// "" is BuiltinRecord's "no features", so an explicit empty expression is refused.
	expect_fault("foo\n.param_str = \"v\"\n.features = \"\"\n", generate_def::UNKNOWN_VALUE, 3, ".features = \"\"");
}

fn void missing_param_str() @test
{
	expect_fault("foo\n.header = .stdio\nbar\n.param_str = \"v\"\n", generate_def::MISSING_PARAM_STR, 1, "foo");
	expect_fault("foo\n.param_str = \"v\"\n\nbar\n.attributes = .{}\n", generate_def::MISSING_PARAM_STR, 4, "bar");
	expect_fault("foo\n", generate_def::MISSING_PARAM_STR, 1, "foo");
}

fn void features_not_allowed() @test
{
	foreach (g : BuiltinGroup::values)
	{
		String text = "foo\n.param_str = \"v\"\n.features = \"x\"\n";
		if (g.has_features)
		{
			DefFile f = parse_ok(g, text);
			assert(f.entries[0].record.features == "x");
			f.free();
		}
		else
		{
			expect_fault(text, generate_def::FEATURES_NOT_ALLOWED, 3, "features", g);
		}
	}
}

fn void too_many_builtins() @test
{
	@pool()
	{
		DString s;
		s.init(tmem);
		for (uint i = 0; i < 65535; i++) s.appendf("b%d\n.param_str = \"v\"\n", i);
		DefFile f = parse_ok(X86, s.str_view());
		check(f.entries.len(), 65535);
		f.free();
		s.append("b65535\n.param_str = \"v\"\n");
		expect_fault(s.str_view(), generate_def::TOO_MANY_BUILTINS, 65536 * 2 - 1, "b65535");
	};
}

fn void no_leaks() @test
{
	TrackingAllocator t;
	t.init(mem);
	defer t.free();
	@pool()
	{
		DefFile f = generate_def::parse_def(&t, load_def(ARM), ARM, null)!!;
		f.free();
		DefDiag diag;
		assert(@catch(generate_def::parse_def(&t, "a\n.param_str = \"v\"\nb\n.param_str = \"v\"\na\n", ARM, &diag)) == generate_def::DUPLICATE_NAME);
		assert(@catch(generate_def::parse_def(&t, "a\n.param_str = \"v\"\n.bogus = 1\n", ARM, null)) == generate_def::UNKNOWN_PROPERTY);
	};
	check(t.allocation_count(), 0);
}
