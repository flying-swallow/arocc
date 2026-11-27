// `lex_probe <file>...`: lex each file with aro::frontend::c3::lexer and print
// the token stream in the format of `c3c --lex-only` (compiler.c compiler_lex),
// so the two can be diffed. Diagnostics go to stderr; exit 1 if any error.
module c3_lex_probe;
import aro::frontend::c3::lexer, aro::frontend::c3::tokens, aro::frontend::c3::symtab, aro::frontend::c3::diagnostics;
import std::io, std::io::file, std::core::mem::alloc;

fn int main(String[] args)
{
	Symtab st;
	st.init(mem);
	defer st.free();
	Diagnostics d;
	d.init_writer(mem, io::stderr(), false);
	defer d.free();
	foreach (path : args[1..])
	{
		char[]? raw = file::load(mem, path);
		if (catch raw)
		{
			io::eprintfn("cannot read %s", path);
			return 2;
		}
		defer alloc::free(mem, raw.ptr);
		String? src = lexer::clean_source(mem, raw);
		if (catch src)
		{
			io::eprintfn("%s: not UTF-8", path);
			return 2;
		}
		defer alloc::free(mem, src.ptr);
		uint id = d.add_file(path);
		Lexer l;
		l.init(mem, &st, &d, id, src);
		io::printfn("# %s", path);
		while (l.next_token())
		{
			io::printf("%s ", l.token_type.text);
			if (l.token_type == TokenType.STRING) alloc::free(mem, l.data.string.ptr);
			if (l.token_type == TokenType.EOF) break;
		}
		io::printn("");
	}
	return d.errors == 0 ? 0 : 1;
}
