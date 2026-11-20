module gen_x86_encodings_tests;
import std, gen_x86_encodings;

fn void enum_tokens_follow_python_findall() @test
{
	String src = "pub const Op = enum(u8) { // skip me\n    none, @\"64bit\", r0x10 = 3,\n    pub fn f() void {}\n};\n";
	String[] toks = gen_x86_encodings::zig_enum(tmem, src, "Op")!!;
	test::eq(toks.len, 3);
	test::eq(toks[0], "none");
	test::eq(toks[1], "@\"64bit\"");
	test::eq(gen_x86_encodings::ident(toks[1]), "64bit");
	test::eq(toks[2], "r0x10");
	// `3` is not a token and the body ends at "\n    pub fn ".
	assert(@catch(gen_x86_encodings::zig_enum(tmem, src, "Mode")));
}

fn void row_alternation_backtracks() @test
{
	Row r;
	String row = ".{ .@\"a b\", .rm, .{ .r32, .rm32 }, .{ 0x01 }, 0, .none, .@\"64bit\" }";
	sz end = gen_x86_encodings::match_row(row, 0, &r);
	test::eq(end, row.len);
	test::eq(r.mnemonic, ".@\"a b\"");
	test::eq(r.op_en, "rm");
	test::eq(r.ops, " .r32, .rm32 ");
	test::eq(r.opc, " 0x01 ");
	test::eq(r.ext, "0");
	test::eq(r.mode, "none");
	test::eq(r.feature, ".@\"64bit\"");
	// The feature's first alternative is `\.\w+`, so `.@none` cannot match.
	assert(!gen_x86_encodings::match_row(".{ .add, .rm, .{}, .{ 0x01 }, 0, .none, .@none }", 0, &r));
	Row[] rows = gen_x86_encodings::find_rows(tmem, ".{ .{ .add,.z,.{},.{0x1},0,.none,.none} .{ .x }");
	test::eq(rows.len, 1);
	test::eq(rows[0].mnemonic, ".add");
}

fn void approved_legacy_sse_rows_are_selected_selectively() @test
{
	String[] expected_sse = {
		"addss", "andps", "comiss", "cvtsi2ss", "cvttss2si", "divss", "movaps", "movss",
		"mulss", "subss", "ucomiss", "xorps",
	};
	String[] expected_sse2 = {
		"addsd", "andpd", "comisd", "cvtsd2ss", "cvtsi2sd", "cvtss2sd", "cvttsd2si", "divsd",
		"movd", "movq", "movsd", "mulsd", "pxor", "subsd", "ucomisd", "xorpd",
	};
	String[] expected_extra = { "setp", "setnp", "jp", "jnp" };
	test::eq(gen_x86_encodings::SSE_MNEMONICS.len, expected_sse.len);
	test::eq(gen_x86_encodings::SSE2_MNEMONICS.len, expected_sse2.len);
	foreach (m : expected_sse) assert(gen_x86_encodings::in_list(&gen_x86_encodings::SSE_MNEMONICS, m));
	foreach (m : expected_sse2) assert(gen_x86_encodings::in_list(&gen_x86_encodings::SSE2_MNEMONICS, m));
	test::eq(gen_x86_encodings::PARITY_MNEMONICS.len, expected_extra.len);
	foreach (m : expected_extra)
		assert(gen_x86_encodings::in_list(&gen_x86_encodings::PARITY_MNEMONICS, m));
	assert(gen_x86_encodings::is_approved_mnemonic("setp"));
	assert(gen_x86_encodings::is_approved_mnemonic("jnp"));
	assert(!gen_x86_encodings::is_approved_mnemonic("addps"));
	assert(!gen_x86_encodings::is_approved_mnemonic("cmpsd"));
	assert(!gen_x86_encodings::is_approved_mnemonic("setpe"));

	String zon =
		".{ .addss, .rm, .{ .xmm, .xmm_m32 }, .{ 0xf3, 0x0f, 0x58 }, 0, .none, .sse }\n"
		".{ .movss, .rm, .{ .xmm, .xmm_m32 }, .{ 0xf3, 0x0f, 0x10 }, 0, .none, .sse }\n"
		".{ .addsd, .rm, .{ .xmm, .xmm_m64 }, .{ 0xf2, 0x0f, 0x58 }, 0, .none, .sse2 }\n"
		".{ .cvtsi2ss, .rm, .{ .xmm, .rm32 }, .{ 0xf3, 0x0f, 0x2a }, 0, .long, .sse }\n"
		".{ .movaps, .rm, .{ .xmm, .xmm_m128 }, .{ 0xc5, 0xf8, 0x28 }, 0, .vex_128_wig, .avx }\n"
		".{ .addps, .rm, .{ .xmm, .xmm_m128 }, .{ 0x0f, 0x58 }, 0, .none, .sse }\n"
		".{ .addss, .rm, .{ .xmm, .xmm_m32 }, .{ 0xf3, 0x0f, 0x58 }, 0, .vex_128_wig, .sse }\n"
		".{ .addss, .rm, .{ .xmm, .xmm_m32 }, .{ 0x90, 0x58 }, 0, .none, .sse }\n"
		".{ .addss, .rm, .{ .xmm, .xmm_m32 }, .{ 0xf3, 0x0f, 0x58 }, 0, .none, .sse4_1 }\n"
		".{ .addss, .rm, .{ .xmm, .xmm_m32 }, .{ 0xf3, 0x0f, 0x58 }, 0, .none, .sse2 }\n"
		".{ .addss, .rm, .{ .xmm, .xmm_m32 }, .{ 0xf3, 0x0f, 0x58 }, 0, .short, .sse }\n"
		".{ .addss, .rm, .{ .xmm, .xmm_m32 }, .{ 0xf3, 0x0f, 0x38 }, 0, .none, .sse }\n"
		".{ .jp, .d, .{ .rel32 }, .{ 0x0f, 0x8a }, 0, .none, .none }\n"
		".{ .setnp, .m, .{ .rm8 }, .{ 0x0f, 0x9b }, 0, .none, .none }\n"
		".{ .movsd, .z, .{}, .{ 0xa5 }, 0, .none, .none }\n";
	Row[] rows = gen_x86_encodings::find_rows(tmem, zon);
	test::eq(rows.len, 15);
	int included = 0;
	foreach (row : rows)
	{
		if (gen_x86_encodings::include_row(row)) included++;
	}
	test::eq(included, 7);
	assert(gen_x86_encodings::include_feature("add", "none"));
	assert(gen_x86_encodings::include_feature("add", "64bit"));
	assert(gen_x86_encodings::include_feature("jp", "none"));
	assert(gen_x86_encodings::include_feature("setnp", "none"));
	assert(!gen_x86_encodings::include_feature("jp", "sse"));
	assert(!gen_x86_encodings::include_feature("setp", "sse2"));
	assert(gen_x86_encodings::include_feature("addss", "sse"));
	assert(!gen_x86_encodings::include_feature("addss", "sse2"));
	assert(gen_x86_encodings::include_feature("addsd", "sse2"));
	foreach (m : expected_sse)
	{
		assert(gen_x86_encodings::include_feature(m, "sse"));
		assert(!gen_x86_encodings::include_feature(m, "sse2"));
		assert(!gen_x86_encodings::include_feature(m, "none"));
	}
	foreach (m : expected_sse2)
	{
		assert(gen_x86_encodings::include_feature(m, "sse2"));
		assert(!gen_x86_encodings::include_feature(m, "sse"));
		if (m != "movsd") assert(!gen_x86_encodings::include_feature(m, "none"));
	}
	assert(!gen_x86_encodings::include_feature("addps", "sse"));
	assert(!gen_x86_encodings::include_feature("mov", "sse"));
	assert(!gen_x86_encodings::include_feature("mov", "sse2"));
	assert(gen_x86_encodings::include_feature("movsd", "none"));
	assert(gen_x86_encodings::include_feature("movd", "sse2"));
	assert(gen_x86_encodings::include_feature("pxor", "sse2"));
	assert(!gen_x86_encodings::include_feature("paddq", "sse2"));
	assert(!gen_x86_encodings::include_feature("prefetchnta", "prefetch"));
	assert(gen_x86_encodings::include_row(rows[1]), "mandatory F3 prefix is a legacy SSE encoding");
	assert(gen_x86_encodings::include_row(rows[2]), "mandatory F2 prefix is a legacy SSE2 encoding");
	assert(gen_x86_encodings::include_row(rows[3]), "REX.W is valid on a legacy SSE conversion form");
	assert(gen_x86_encodings::include_row(rows[12]), "parity branch uses a baseline x86 encoding");
	assert(gen_x86_encodings::include_row(rows[14]), "MOVSD string operation remains unfeatured");
}
