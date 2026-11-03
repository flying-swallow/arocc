// Owner: 12.2 table-gen (written by plan 12 stage 0).
// Command line entry of //tools:generate_def, run by the `builtin_defs` rule
// in tools/builtins.bzl:
//
//     generate_def <input.def> <output.c3> <group>
//
// <group> is a BuiltinGroup.def_name. Kept apart from the parser/emitter so
// that unit tests can link those without a second `main`.
//
// Invariants: exit 0 and write the output only on success; on any error print
// "<input>:<line>: error: <fault>: <detail>" to stderr, exit 1, write nothing.
module generate_def_main;
import std::io, std::io::file, generate_def, aro::builtin_properties;

fn String basename(String path)
{
	sz start = 0;
	foreach (i, c : path) if (c == '/' || c == '\\') start = i + 1;
	return path[start..];
}

fn int main(String[] args)
{
	if (args.len != 4)
	{
		io::eprintfn("Usage: %s <input-file> <output-path> <group>", args.len ? args[0] : "generate_def");
		return 1;
	}
	String input_path = args[1];
	String output_path = args[2];
	BuiltinGroup? group = builtin_properties::group_from_name(args[3]);
	if (catch group)
	{
		io::eprintfn("%s: error: unknown builtin group '%s'", input_path, args[3]);
		return 1;
	}
	char[]? input = file::load(mem, input_path);
	if (catch f = input)
	{
		io::eprintfn("%s: error: cannot read: %s", input_path, f);
		return 1;
	}
	defer free(input);

	DefDiag diag;
	DefFile? parsed = generate_def::parse_def(mem, (String)input, group, &diag);
	if (catch f = parsed)
	{
		io::eprintfn("%s:%d: error: %s: %s", input_path, diag.line, f, diag.detail);
		return 1;
	}
	defer parsed.free();

	String out = generate_def::emit_table(mem, &parsed, basename(input_path));
	defer free(out.ptr);
	if (catch f = file::save(output_path, out))
	{
		io::eprintfn("%s: error: cannot write: %s", output_path, f);
		return 1;
	}
	return 0;
}
