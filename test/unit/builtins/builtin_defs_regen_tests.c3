// Plan 12 stage 2: regeneration determinism of the builtin tables.
//
// For each of the 19 .def files (Bazel data), parse + emit twice in-process
// and require identical bytes, then require that the output of the Bazel
// GenerateDef action (//:builtin_defs, also Bazel data, produced by the
// //tools:generate_def binary) equals the in-process emit byte for byte. That
// ties the tables compiled into //:aro_c3_lib to a pure function of the .def
// text. No Zig output is involved.
module builtin_defs_regen_tests;
import std::io, generate_def, aro::builtin_properties;

fn String emit_group(BuiltinGroup g, String text)
{
	DefDiag diag;
	DefFile? f = generate_def::parse_def(mem, text, g, &diag);
	if (catch err = f)
	{
		io::eprintfn("%s.def:%d: %s: %s", g.def_name, diag.line, err, diag.detail);
		unreachable("parse failed");
	}
	defer f.free();
	return generate_def::emit_table(tmem, &f, string::tformat("%s.def", g.def_name));
}

fn void regenerate_twice_identical() @test
{
	foreach (g : BuiltinGroup::values)
	{
		String text = (String)file::load(tmem, string::tformat("src/aro/Builtins/%s.def", g.def_name))!!;
		String first = emit_group(g, text);
		String second = emit_group(g, text);
		assert(first == second, "%s: regeneration differs", g.def_name);
		String built = (String)file::load(tmem, string::tformat("builtin_defs/%s.c3", g.def_name))!!;
		assert(built == first, "%s: bazel-generated table differs from in-process emit", g.def_name);
	}
}
