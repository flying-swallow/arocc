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
