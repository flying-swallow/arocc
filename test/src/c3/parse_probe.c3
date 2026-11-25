// `parse_probe <file>...`: parse every file with the c3 frontend parser into
// one fresh compiler (like `c3c -P compile <files>`, parse only). Errors go to
// stderr as "(path:row:col) Error: text"; exit 1 if any file had errors.
module c3_parse_probe;
import aro::frontend::c3::compiler, aro::frontend::c3::diagnostics;
import aro::terminal, std::io, std::io::file, std::core::mem::alloc;

fn int main(String[] args)
{
	compiler::compiler_reset();
	defer compiler::compiler_free();
	compiler::global_diagnostics.output = TO_WRITER;
	compiler::global_diagnostics.terminal = { .writer = io::stderr(), .mode = NO_COLOR };
	int failed = 0;
	foreach (path : args[1..])
	{
		char[]? raw = file::load(mem, path);
		if (catch raw)
		{
			io::eprintfn("cannot read %s", path);
			return 2;
		}
		defer alloc::free(mem, raw.ptr);
		SourceFile* f = compiler::source_file_text_load(path, (String)raw);
		compiler::global_context_clear_errors();
		if (!compiler::parse_file(f)) failed++;
	}
	return failed == 0 ? 0 : 1;
}
