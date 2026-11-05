// Tests for src/c3/pp_feature_queries.c3 (plan 14.5 `queries`): has_feature /
// has_extension, the Compilation.is_target_* queries, paste_strings_unsafe,
// reconstruct_include_string, handle_builtin_macro and builtin_expand_func.
// Builtin macro arguments are fed directly (lexed from a fixture-shaped line;
// whitespace becomes MACRO_WS as in macro argument collection), not through
// the macro expander. The file services are a fake FileProvider.
//
// Provenance of expected values (no Zig executable was run):
//  [fixture X]  test/cases/X (its #error structure, args and manifest
//               diagnostics, including line:column).
//  [source]     derived by reading src/aro/features.zig, Compilation.zig
//               isTarget*, Target.zig and Preprocessor.zig
//               handleBuiltinMacro / expandFuncMacro / reconstructIncludeString.
module pp_feature_queries_tests;
import aro::preprocessor, aro::tokens, aro::tokenizer, aro::source, aro::compilation, aro::diagnostics;
import aro::target, aro::lang_opts;
import std::io, std::core::mem::allocators, std::collections::list;

macro check(left, right)
{
	test::eq((long)left, (long)right);
}

const Host HOST = { X86_64, LINUX, GNU };

fn Target tgt(String triple)
{
	Target? t = target::parse_triple(triple, HOST);
	if (catch f = t)
	{
		io::eprintfn("failed to parse target '%s': %s", triple, f);
		unreachable("target parse failed");
	}
	return t;
}

<* Run the body with a compilation for `triple` (diagnostics to a list) and a preprocessor; checks for leaks. *>
macro @with_pp(String triple; @body(Compilation* comp, Diagnostics* d, Preprocessor* pp))
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		Compilation comp;
		comp.init(&ta, null, &d);
		comp.target = tgt(triple);
		Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		@body(&comp, &d, &pp);
		pp.free();
		comp.free();
		d.free();
	}
	check(ta.allocation_count(), 0);
}

// ---------------------------------------------------------------------------
// Fake file services

struct FakeFiles
{
	int calls;
	char[64] name_buf;
	sz name_len;
	SourceId includer;
	IncludeType include_type;
	WhichInclude which;
	ulong limit;
	bool answer;
	bool embed_found;
	String embed_contents;
}

FakeFiles fake;

fn String fake_name() => (String)fake.name_buf[:fake.name_len];

fn void record(String filename, SourceId includer, IncludeType t)
{
	fake.calls++;
	fake.name_len = filename.len;
	fake.name_buf[:filename.len] = filename[..];
	fake.includer = includer;
	fake.include_type = t;
}

fn bool? fake_has_include(void* ctx, Preprocessor* pp, String filename, SourceId includer, IncludeType t, WhichInclude which)
{
	record(filename, includer, t);
	fake.which = which;
	return fake.answer;
}

fn char[]? fake_find_embed(void* ctx, Preprocessor* pp, String filename, SourceId includer, IncludeType t, ulong limit)
{
	record(filename, includer, t);
	fake.limit = limit;
	if (!fake.embed_found) return preprocessor::FILE_NOT_FOUND~;
	if (fake.embed_contents.len == 0) return {};
	char[] bytes = alloc::new_array(pp.comp.gpa, char, fake.embed_contents.len);
	bytes[..] = fake.embed_contents[..];
	return bytes;
}

fn void use_fake_files(Preprocessor* pp, bool answer = true)
{
	fake = { .answer = answer, .embed_found = true };
	pp.files = {
		null,
		&preprocessor::unsupported_find_include,
		&fake_has_include,
		&fake_find_embed,
		&preprocessor::unsupported_source_mtime,
	};
}

// ---------------------------------------------------------------------------
// Feeding builtin macro calls

int source_counter;

<*
 Lex `src` from byte `from` up to (not including) byte `to` into `out`
 (tokens::from_raw; WHITESPACE and NL -> MACRO_WS).
*>
fn void lex_range(Compilation* comp, Source src, uint from, uint to, ExpandBuf* out)
{
	Tokenizer t;
	t.init(src.buf, src.id, comp.langopts);
	while (true)
	{
		Token raw = t.next();
		if (raw.id == EOF || raw.start >= to) break;
		if (raw.start < from) continue;
		TokenWithExpansionLocs tok = tokens::from_raw(raw);
		if (tok.id == WHITESPACE || tok.id == NL) tok.id = MACRO_WS;
		out.push(tok);
	}
}

<*
 Expand the builtin `kind` called as `name(...)` in `line` (a fresh source,
 so columns match the fixture line): the argument is everything between the
 '(' after `name` and the last ')' of the line. Returns the spelling of the
 resulting tokens (temp allocator).
*>
fn String? expand_line(Preprocessor* pp, BuiltinFunc kind, String name, String line, EvalContext ctx = EXPR)
{
	Compilation* comp = pp.comp;
	Source src = comp.add_source_from_buffer(string::tformat("q%d.c", source_counter++), line)!!;
	sz name_at = line.index_of(name)!!;
	sz lparen = name_at + name.len;
	while (line[lparen] != '(') lparen++;
	sz rparen = line.rindex_of(")")!!;

	ExpandBuf macro_buf;
	macro_buf.init(comp.gpa);
	defer preprocessor::free_expand_buf(comp.gpa, &macro_buf);
	lex_range(comp, src, (uint)name_at, (uint)(name_at + name.len), &macro_buf);
	TokenWithExpansionLocs macro_tok = macro_buf[0];

	ExpandBuf arg;
	arg.init(comp.gpa);
	defer preprocessor::free_expand_buf(comp.gpa, &arg);
	lex_range(comp, src, (uint)lparen + 1, (uint)rparen, &arg);

	MacroArguments args;
	args.init(comp.gpa);
	defer args.free();
	args.push(arg.array_view());

	ExpandBuf out;
	out.init(comp.gpa);
	defer preprocessor::free_expand_buf(comp.gpa, &out);
	RawToken raw = { .id = MACRO_PARAM_BUILTIN_FUNC, .source = source::GENERATED_ID };
	preprocessor::builtin_expand_func(null, pp, kind, macro_tok, raw, &args, ctx, &out)!;

	// Generated tokens: the generated_buf text through its '\n' (checks the
	// exact text written). Others: the token spelling.
	DString s;
	s.tinit();
	foreach (t : out.array_view())
	{
		if (t.loc.id.is_generated())
		{
			check(t.id.ordinal, TokenId.PP_NUM.ordinal);
			String gen = (String)comp.generated_buf.array_view();
			sz end = t.loc.byte_offset;
			while (gen[end] != '\n') end++;
			s.append(gen[t.loc.byte_offset..end]);
			continue;
		}
		if (t.id == IDENTIFIER) s.append("ident:");
		s.append(pp.expanded_slice(t));
	}
	return s.str_view();
}

<* expand_line that must succeed. *>
fn String ex(Preprocessor* pp, BuiltinFunc kind, String name, String line, EvalContext ctx = EXPR)
{
	String? r = expand_line(pp, kind, name, line, ctx);
	if (catch f = r)
	{
		io::eprintfn("expansion of '%s' failed: %s", line, f);
		unreachable("expansion failed");
	}
	return r;
}

<* Check message `i`: text, line and column. *>
fn void msg(Diagnostics* d, sz i, String text, uint line, uint col)
{
	test::eq(d.messages[i].text, text);
	check(d.messages[i].location.line_no, line);
	check(d.messages[i].location.col, col);
}

// ---------------------------------------------------------------------------
// has_feature / has_extension

fn void features() @test
{
	@with_pp("x86_64-linux-gnu"; Compilation* comp, Diagnostics* d, Preprocessor* pp)
	{
		// [fixture __has_feature.c] normalized name exists; unknown name does not.
		assert(preprocessor::has_feature(comp, "__enumerator_attributes__"));
		assert(!preprocessor::has_feature(comp, "does_not_exist"));
		// [fixture feature as extension.c] features are extensions too.
		assert(preprocessor::has_feature(comp, "attribute_deprecated_with_message"));
		assert(preprocessor::has_extension(comp, "attribute_deprecated_with_message"));
		// [fixture __has_extension.c] default standard.
		assert(preprocessor::has_extension(comp, "c_alignas"));
		assert(!preprocessor::has_extension(comp, "does_not_exist"));
		// [source] list entries.
		assert(!preprocessor::has_feature(comp, "blocks"));
		assert(preprocessor::has_feature(comp, "nullability_nullable_result"));
		assert(preprocessor::has_feature(comp, "c_static_assert"));
		assert(preprocessor::has_feature(comp, "c_thread_local"));
		assert(!preprocessor::has_feature(comp, "c_attributes"));
		assert(preprocessor::has_extension(comp, "c_attributes"));
		assert(preprocessor::has_extension(comp, "c_fixed_enum"));
		assert(!preprocessor::has_feature(comp, "bounds_attributes"));
		comp.langopts.bounds_safety = CLANG;
		assert(preprocessor::has_feature(comp, "bounds_attributes"));
		assert(preprocessor::has_extension(comp, "statement_attributes_with_gnu_syntax"));
		assert(!preprocessor::has_extension(comp, "overloadable_unmarked"));
		assert(!preprocessor::has_extension(comp, "matrix_types"));
		assert(!preprocessor::has_extension(comp, "matrix_types_scalar_division"));
		assert(preprocessor::has_extension(comp, "gnu_asm"));
		assert(preprocessor::has_extension(comp, "__gnu_asm_goto_with_outputs__"));
		comp.langopts.gnu_asm = false;
		assert(!preprocessor::has_extension(comp, "gnu_asm"));
		assert(preprocessor::has_extension(comp, "define_target_os_macros"));
		comp.langopts.emulate = GCC;
		assert(!preprocessor::has_extension(comp, "define_target_os_macros"));
		// [source] "__x" / "x__" / "____" edge cases of Attribute.normalize.
		test::eq(preprocessor::attribute_normalize("____"), "");
		test::eq(preprocessor::attribute_normalize("__x"), "__x");
		test::eq(preprocessor::attribute_normalize("__nullability"), "__nullability");
		assert(!preprocessor::has_feature(comp, "__nullability"));

		comp.langopts.standard = C23;
		assert(preprocessor::has_feature(comp, "c_attributes"));
		assert(preprocessor::has_feature(comp, "c_fixed_enum"));

		// C99: C11 features are only extensions.
		comp.langopts.standard = C99;
		assert(!preprocessor::has_feature(comp, "c_alignas"));
		assert(preprocessor::has_extension(comp, "c_alignas"));
		assert(preprocessor::has_extension(comp, "c_thread_local"));
		// [source] has_extension normalizes before has_feature, which normalizes
		// again; the extension list then sees the once-normalized name.
		assert(!preprocessor::has_extension(comp, "____c_alignas____"));
		comp.langopts.standard = C11;
		assert(preprocessor::has_extension(comp, "____c_alignas____"));
		comp.langopts.standard = C99;

		// [fixture feature as extension pedantic.c] -pedantic-errors -std=c99.
		d.state.extensions = ERROR;
		assert(!preprocessor::has_extension(comp, "c_alignas"));
		assert(preprocessor::has_extension(comp, "attribute_deprecated_with_message"));
		d.state.extensions = FATAL_ERROR;
		assert(!preprocessor::has_extension(comp, "c_alignas"));
		d.state.extensions = WARNING;
		assert(preprocessor::has_extension(comp, "c_alignas"));
		check(d.messages.len(), 0);
	};
}

fn void thread_local_needs_tls() @test
{
	// [source] Target.isTlsSupported is false for x86.
	@with_pp("x86-linux-gnu"; Compilation* comp, Diagnostics* d, Preprocessor* pp)
	{
		comp.langopts.standard = C11;
		assert(!preprocessor::has_feature(comp, "c_thread_local"));
		assert(!preprocessor::has_extension(comp, "c_thread_local"));
		assert(preprocessor::has_feature(comp, "c_atomic"));
	};
}

// ---------------------------------------------------------------------------
// is_target_*

fn void target_arch() @test
{
	// [fixture __is_target_arch.c] -target x86-linux-gnu
	@with_pp("x86-linux-gnu"; Compilation* comp, Diagnostics* d, Preprocessor* pp)
	{
		assert(comp.is_target_arch("x86"));
		assert(!comp.is_target_arch("x86_64"));
	};
	// [source] sub-arch: the feature must be enabled; generic aarch64 has no v8.1a.
	@with_pp("aarch64-linux-gnu"; Compilation* comp, Diagnostics* d, Preprocessor* pp)
	{
		assert(comp.is_target_arch("aarch64"));
		assert(comp.is_target_arch("arm64"));
		assert(!comp.is_target_arch("x86_64"));
		assert(!comp.is_target_arch("aarch64v8.1a"));
	};
}

fn void target_os_vendor_env() @test
{
	// [fixture __is_target_os.c] --target=x86_64-linux
	@with_pp("x86_64-linux"; Compilation* comp, Diagnostics* d, Preprocessor* pp)
	{
		assert(comp.is_target_os("linux"));
		assert(!comp.is_target_os("windows"));
		assert(!comp.is_target_os("macos"));
		// [source] not darwin: variant queries are false.
		assert(!comp.is_target_variant_os("linux"));
		assert(!comp.is_target_variant_environment("gnu"));
	};
	// [fixture __is_target_vendor.c]
	@with_pp("x86_64-pc-linux-gnu"; Compilation* comp, Diagnostics* d, Preprocessor* pp)
	{
		assert(comp.is_target_vendor("pc"));
		assert(!comp.is_target_vendor("apple"));
	};
	// [fixture __is_target_darwin.c] --target=aarch64-macos: all darwin OSes match.
	@with_pp("aarch64-macos"; Compilation* comp, Diagnostics* d, Preprocessor* pp)
	{
		assert(comp.is_target_os("iOS"));
		// [source] darwin without a variant triple.
		assert(!comp.is_target_variant_os("ios"));
	};
	// [fixture __is_target_clang_compat.c] --target=x86_64-apple-darwin-simulator
	@with_pp("x86_64-apple-darwin-simulator"; Compilation* comp, Diagnostics* d, Preprocessor* pp)
	{
		assert(comp.is_target_arch("x86_64"));
		assert(comp.is_target_arch("X86_64"));
		assert(!comp.is_target_arch("arm64"));
		assert(!comp.is_target_arch("foo"));
		assert(comp.is_target_vendor("apple"));
		assert(comp.is_target_vendor("APPLE"));
		assert(!comp.is_target_vendor("unknown"));
		assert(!comp.is_target_vendor("foo"));
		assert(comp.is_target_os("darwin"));
		assert(comp.is_target_os("DARWIN"));
		assert(!comp.is_target_os("foo"));
		assert(comp.is_target_abi("simulator"));
		assert(comp.is_target_abi("SIMULATOR"));
		assert(!comp.is_target_abi("unknown"));
		assert(!comp.is_target_abi("foo"));
		assert(!comp.is_target_abi("macabi"));
	};
}

fn void target_variant() @test
{
	// [fixture __is_target_variant.c] -target aarch64-macos-none
	// -darwin-target-variant-triple x86_64-ios.13.1-macabi
	@with_pp("aarch64-macos-none"; Compilation* comp, Diagnostics* d, Preprocessor* pp)
	{
		comp.has_darwin_target_variant = true;
		comp.darwin_target_variant = tgt("x86_64-ios.13.1-macabi");
		assert(comp.is_target_variant_os("ios"));
		assert(comp.is_target_variant_os("macos"));
		assert(comp.is_target_variant_environment("macABI"));
		assert(!comp.is_target_variant_environment("none"));
	};
}

// ---------------------------------------------------------------------------
// Identifier queries through builtin_expand_func

fn void identifier_queries() @test
{
	@with_pp("x86_64-apple-darwin-simulator"; Compilation* comp, Diagnostics* d, Preprocessor* pp)
	{
		comp.langopts.emulate = CLANG;
		// [fixture __is_target_clang_compat.c]
		test::eq(ex(pp, IS_TARGET_ARCH, "__is_target_arch", "#if !__is_target_arch(X86_64)"), "1\n");
		test::eq(ex(pp, IS_TARGET_ARCH, "__is_target_arch", "#if !__is_target_arch(x86_64)"), "1\n");
		test::eq(ex(pp, IS_TARGET_VENDOR, "__is_target_vendor", "#if __is_target_vendor(unknown)"), "0\n");
		test::eq(ex(pp, IS_TARGET_OS, "__is_target_os", "#if !__is_target_os(DARWIN)"), "1\n");
		test::eq(ex(pp, IS_TARGET_ENVIRONMENT, "__is_target_environment", "#if !__is_target_environment(simulator)"), "1\n");
		test::eq(ex(pp, IS_TARGET_ENVIRONMENT, "__is_target_environment", "#if __is_target_environment(macabi)"), "0\n");
		test::eq(ex(pp, HAS_BUILTIN, "__has_builtin", "#if !__has_builtin(__is_target_environment)"), "1\n");
		check(d.messages.len(), 0);
		// [fixture __is_target_clang_compat.c:58:22] a number is not an identifier.
		test::eq(ex(pp, IS_TARGET_ARCH, "__is_target_arch", "#if __is_target_arch(11)"), "0\n");
		check(d.messages.len(), 1);
		msg(d, 0, "builtin feature check macro requires a parenthesized identifier", 1, 22);
		// [source] two identifiers: reported at the second one.
		test::eq(ex(pp, HAS_FEATURE, "__has_feature", "#if __has_feature(nullability  blocks)"), "0\n");
		msg(d, 1, "builtin feature check macro requires a parenthesized identifier", 1, 32);
		// [source] comments and whitespace are skipped.
		test::eq(ex(pp, HAS_FEATURE, "__has_feature", "#if __has_feature( /* c */ nullability )"), "1\n");
		check(d.messages.len(), 2);
		// [source] empty argument list: expected_arguments at the macro name.
		test::eq(ex(pp, HAS_FEATURE, "__has_feature", "#if __has_feature()"), "0\n");
		msg(d, 2, "expected 1 argument(s) got 0", 1, 5);
		// [source] only whitespace: an EOF token at the macro location.
		test::eq(ex(pp, HAS_FEATURE, "__has_feature", "#if __has_feature(  )"), "0\n");
		msg(d, 3, "builtin feature check macro requires a parenthesized identifier", 1, 5);
		check(d.messages.len(), 4);
	};
}

fn void has_builtin() @test
{
	// [fixture __has_builtin.c] --emulate=clang
	@with_pp("x86_64-linux-gnu"; Compilation* comp, Diagnostics* d, Preprocessor* pp)
	{
		comp.langopts.emulate = CLANG;
		test::eq(ex(pp, HAS_BUILTIN, "__has_builtin", "#  if __has_builtin(__builtin_va_start)"), "1\n");
		test::eq(ex(pp, HAS_BUILTIN, "__has_builtin", "#  if __has_builtin(__builtin_va_arg)"), "1\n");
		test::eq(ex(pp, HAS_BUILTIN, "__has_builtin", "#  if __has_builtin(__builtin_foobar)"), "0\n");
		test::eq(ex(pp, HAS_BUILTIN, "__has_builtin", "#if __has_builtin(__has_builtin)"), "0\n");
		test::eq(ex(pp, HAS_BUILTIN, "__has_builtin", "#if !__has_builtin(__is_target_arch)"), "1\n");
		// [source] the special cases need emulate NO or CLANG.
		comp.langopts.emulate = NO;
		test::eq(ex(pp, HAS_BUILTIN, "__has_builtin", "#if !__has_builtin(__is_target_variant_os)"), "1\n");
		comp.langopts.emulate = GCC;
		test::eq(ex(pp, HAS_BUILTIN, "__has_builtin", "#if !__has_builtin(__is_target_arch)"), "0\n");
		// [source] x86 target builtins are found through the arch groups.
		test::eq(ex(pp, HAS_BUILTIN, "__has_builtin", "#if __has_builtin(__builtin_ia32_pause)"), "1\n");
		check(d.messages.len(), 0);
	};
}

fn void feature_and_extension_macros() @test
{
	@with_pp("x86_64-linux-gnu"; Compilation* comp, Diagnostics* d, Preprocessor* pp)
	{
		// [fixture __has_feature.c] / [fixture __has_extension.c]
		test::eq(ex(pp, HAS_FEATURE, "__has_feature", "#  if __has_feature(__enumerator_attributes__)"), "1\n");
		test::eq(ex(pp, HAS_FEATURE, "__has_feature", "#  if __has_feature(does_not_exist)"), "0\n");
		test::eq(ex(pp, HAS_EXTENSION, "__has_extension", "#  if __has_extension(c_alignas)"), "1\n");
		test::eq(ex(pp, HAS_EXTENSION, "__has_extension", "#  if __has_extension(does_not_exist)"), "0\n");
		// [fixture builtin macro errors.c] __has_feature(__const__): a keyword is a macro identifier.
		test::eq(ex(pp, HAS_FEATURE, "__has_feature", "#if __has_feature(__const__)"), "0\n");
		check(d.messages.len(), 0);
	};
}

fn void attribute_queries_use_shared_namespaced_tables() @test
{
	@with_pp("x86_64-linux-gnu"; Compilation* comp, Diagnostics* d, Preprocessor* pp)
	{
		// [source-derived] shared Attribute.Namespaced tables recognize GNU attributes.
		test::eq(ex(pp, HAS_ATTRIBUTE, "__has_attribute", "#if __has_attribute(aligned)"), "1\n");
		// [fixture builtin macro errors.c:1:21] diagnosed before the attribute lookup.
		test::eq(ex(pp, HAS_ATTRIBUTE, "__has_attribute", "#if __has_attribute(42)"), "0\n");
		msg(d, 0, "builtin feature check macro requires a parenthesized identifier", 1, 21);
		// [fixture no declspec.c] without -fdeclspec the answer is 0.
		test::eq(ex(pp, HAS_DECLSPEC_ATTRIBUTE, "__has_declspec_attribute", "#if __has_declspec_attribute(noreturn)"), "0\n");
		comp.langopts.declspec_attrs = true;
		test::eq(ex(pp, HAS_DECLSPEC_ATTRIBUTE, "__has_declspec_attribute", "#if __has_declspec_attribute(noreturn)"), "1\n");
		check(d.messages.len(), 1);
	};
}

fn void has_c_attribute() @test
{
	@with_pp("x86_64-linux-gnu"; Compilation* comp, Diagnostics* d, Preprocessor* pp)
	{
		// [source] the C23 table, on normalized names.
		test::eq(ex(pp, HAS_C_ATTRIBUTE, "__has_c_attribute", "#if __has_c_attribute(deprecated)"), "201904L\n");
		test::eq(ex(pp, HAS_C_ATTRIBUTE, "__has_c_attribute", "#if __has_c_attribute(__fallthrough__)"), "201904L\n");
		test::eq(ex(pp, HAS_C_ATTRIBUTE, "__has_c_attribute", "#if __has_c_attribute(maybe_unused)"), "201904L\n");
		test::eq(ex(pp, HAS_C_ATTRIBUTE, "__has_c_attribute", "#if __has_c_attribute(nodiscard)"), "202003L\n");
		test::eq(ex(pp, HAS_C_ATTRIBUTE, "__has_c_attribute", "#if __has_c_attribute(_Noreturn)"), "202202L\n");
		test::eq(ex(pp, HAS_C_ATTRIBUTE, "__has_c_attribute", "#if __has_c_attribute(noreturn)"), "202202L\n");
		test::eq(ex(pp, HAS_C_ATTRIBUTE, "__has_c_attribute", "#if __has_c_attribute(unsequenced)"), "202207L\n");
		test::eq(ex(pp, HAS_C_ATTRIBUTE, "__has_c_attribute", "#if __has_c_attribute(reproducible)"), "202207L\n");
		test::eq(ex(pp, HAS_C_ATTRIBUTE, "__has_c_attribute", "#if __has_c_attribute(foo)"), "0\n");
		check(d.messages.len(), 0);
		// [source-derived] vendor-qualified lookup uses the shared GNU table.
		test::eq(ex(pp, HAS_C_ATTRIBUTE, "__has_c_attribute", "#if __has_c_attribute(gnu::packed)"), "1\n");
		// [source] '::' first, a dangling vendor, two names, empty.
		test::eq(ex(pp, HAS_C_ATTRIBUTE, "__has_c_attribute", "#if __has_c_attribute(::foo)"), "0\n");
		msg(d, 0, "builtin feature check macro requires a parenthesized identifier", 1, 23);
		test::eq(ex(pp, HAS_C_ATTRIBUTE, "__has_c_attribute", "#if __has_c_attribute(gnu::)"), "0\n");
		msg(d, 1, "builtin feature check macro requires a parenthesized identifier", 1, 23);
		test::eq(ex(pp, HAS_C_ATTRIBUTE, "__has_c_attribute", "#if __has_c_attribute(a b)"), "0\n");
		msg(d, 2, "builtin feature check macro requires a parenthesized identifier", 1, 25);
		test::eq(ex(pp, HAS_C_ATTRIBUTE, "__has_c_attribute", "#if __has_c_attribute()"), "0\n");
		msg(d, 3, "expected 1 argument(s) got 0", 1, 5);
		test::eq(ex(pp, HAS_C_ATTRIBUTE, "__has_c_attribute", "#if __has_c_attribute( )"), "0\n");
		msg(d, 4, "builtin feature check macro requires a parenthesized identifier", 1, 5);
		check(d.messages.len(), 5);
	};
}

fn void has_warning() @test
{
	@with_pp("x86_64-linux-gnu"; Compilation* comp, Diagnostics* d, Preprocessor* pp)
	{
		// [fixture __has_warning.c]
		test::eq(ex(pp, HAS_WARNING, "__has_warning", "#if !__has_warning(\"-Wextern-initializer\")"), "1\n");
		test::eq(ex(pp, HAS_WARNING, "__has_warning", "#if __has_warning(\"-Wfoo\")"), "0\n");
		test::eq(ex(pp, HAS_WARNING, "__has_warning", "#elif !__has_warning(\"-Wunrea\" \"chable-code\")"), "1\n");
		check(d.messages.len(), 0);
		test::eq(ex(pp, HAS_WARNING, "__has_warning", "#if __has_warning(\"foobar\")"), "0\n");
		msg(d, 0, "__has_warning expected option name (e.g. \"-Wundef\")", 1, 19);
		test::eq(ex(pp, HAS_WARNING, "__has_warning", "#elif __has_warning(foobar)"), "0\n");
		msg(d, 1, "expected string literal in '__has_warning'", 1, 21);
		check(d.messages.len(), 2);
		check(pp.char_buf.len(), 0);
	};
}

fn void paste_strings() @test
{
	@with_pp("x86_64-linux-gnu"; Compilation* comp, Diagnostics* d, Preprocessor* pp)
	{
		ExpandBuf buf;
		buf.init(comp.gpa);
		Source src = comp.add_source_from_buffer("p.c", "(\"a\" \"bc\")")!!;
		lex_range(comp, src, 0, (uint)src.buf.len, &buf);
		pp.char_buf.push('x');
		// [source] parenthesized series, quotes dropped, length restored.
		test::eq(pp.paste_strings_unsafe(buf.array_view())!!, "abc");
		check(pp.char_buf.len(), 1);
		// [source] without the closing paren the '(' is not a string literal.
		assert(@catch(pp.paste_strings_unsafe(buf.array_view()[:4])) == preprocessor::EXPECTED_STRING_LITERAL);
		// [source] "()" is an empty series.
		TokenWithExpansionLocs[2] parens = { buf[0], buf[^1] };
		assert(@catch(pp.paste_strings_unsafe(&parens)) == preprocessor::EXPECTED_STRING_LITERAL);
		assert(@catch(pp.paste_strings_unsafe({})) == preprocessor::EXPECTED_STRING_LITERAL);
		check(pp.char_buf.len(), 1);
		preprocessor::free_expand_buf(comp.gpa, &buf);
	};
}

fn void is_identifier() @test
{
	@with_pp("x86_64-linux-gnu"; Compilation* comp, Diagnostics* d, Preprocessor* pp)
	{
		// [fixture __is_identifier.c] -std=c17
		comp.langopts.standard = C17;
		test::eq(ex(pp, IS_IDENTIFIER, "__is_identifier", "#if !__is_identifier(typeof)"), "1\n");
		test::eq(ex(pp, IS_IDENTIFIER, "__is_identifier", "#if __is_identifier(inline)"), "0\n");
		test::eq(ex(pp, IS_IDENTIFIER, "__is_identifier", "#if __is_identifier(for)"), "0\n");
		test::eq(ex(pp, IS_IDENTIFIER, "__is_identifier", "#if __is_identifier(\"foo\")"), "0\n");
		test::eq(ex(pp, IS_IDENTIFIER, "__is_identifier", "#if __is_identifier(_Static_assert)"), "0\n");
		test::eq(ex(pp, IS_IDENTIFIER, "__is_identifier", "#define X __is_identifier(foobar)", NON_EXPR), "1\n");
		test::eq(ex(pp, IS_IDENTIFIER, "__is_identifier", "#if !__is_identifier(FOO)"), "1\n");
		check(d.messages.len(), 0);
		test::eq(ex(pp, IS_IDENTIFIER, "__is_identifier", "#if __is_identifier(foo bar)"), "0\n");
		msg(d, 0, "missing ')', after builtin feature-check macro", 1, 25);
		test::eq(ex(pp, IS_IDENTIFIER, "__is_identifier", "#if __is_identifier()"), "0\n");
		msg(d, 1, "expected 1 argument(s) got 0", 1, 5);
		check(d.messages.len(), 2);
	};
}

// ---------------------------------------------------------------------------
// __has_include / __has_embed (file services are plan 15)

fn void has_include() @test
{
	@with_pp("x86_64-linux-gnu"; Compilation* comp, Diagnostics* d, Preprocessor* pp)
	{
		// [source] contract: the default provider is unsupported.
		assert(@catch(expand_line(pp, HAS_INCLUDE, "__has_include", "#if __has_include(<stdio.h>)")) == aro::UNSUPPORTED);

		use_fake_files(pp);
		test::eq(ex(pp, HAS_INCLUDE, "__has_include", "#if __has_include(<stdio.h>)"), "1\n");
		test::eq(fake_name(), "stdio.h");
		check(fake.include_type.ordinal, IncludeType.ANGLE_BRACKETS.ordinal);
		check(fake.which.ordinal, WhichInclude.FIRST.ordinal);
		// [source] the includer is the macro token's source.
		check(fake.includer.index, comp.sources.len() - 1);
		fake.answer = false;
		test::eq(ex(pp, HAS_INCLUDE, "__has_include", "#if __has_include( \"sub/a b.h\" )"), "0\n");
		test::eq(fake_name(), "sub/a b.h");
		check(fake.include_type.ordinal, IncludeType.QUOTES.ordinal);
		check(d.messages.len(), 0);
		check(pp.char_buf.len(), 0);

		// [source] __has_include_next in the main file: FIRST plus a warning at the macro.
		fake.answer = true;
		test::eq(ex(pp, HAS_INCLUDE_NEXT, "__has_include_next", "#if __has_include_next(<a.h>)"), "1\n");
		check(fake.which.ordinal, WhichInclude.FIRST.ordinal);
		msg(d, 0, "#include_next in primary source file; will search from start of include path", 1, 5);
		pp.include_depth = 1;
		test::eq(ex(pp, HAS_INCLUDE_NEXT, "__has_include_next", "#if __has_include_next(<a.h>)"), "1\n");
		check(fake.which.ordinal, WhichInclude.NEXT.ordinal);
		check(d.messages.len(), 1);
		pp.include_depth = 0;

		// [source] outside #if: diagnosed, still answered.
		test::eq(ex(pp, HAS_INCLUDE, "__has_include", "int x = __has_include(<a.h>);", NON_EXPR), "1\n");
		msg(d, 1, "'__has_include' must be used within a preprocessing directive", 1, 9);

		// [source] reconstruct_include_string failures answer 0 without a lookup.
		int calls = fake.calls;
		test::eq(ex(pp, HAS_INCLUDE, "__has_include", "#if __has_include(\"a.h\" x)"), "0\n");
		// Zig reports at params[1], which is the MACRO_WS before `x`.
		msg(d, 2, "expected closing ')'", 1, 24);
		test::eq(ex(pp, HAS_INCLUDE, "__has_include", "#if __has_include(\"\")"), "0\n");
		msg(d, 3, "empty filename", 1, 19);
		test::eq(ex(pp, HAS_INCLUDE, "__has_include", "#if __has_include(foo)"), "0\n");
		msg(d, 4, "expected \"FILENAME\" or <FILENAME>", 1, 19);
		test::eq(ex(pp, HAS_INCLUDE, "__has_include", "#if __has_include(  )"), "0\n");
		msg(d, 5, "expected \"FILENAME\" or <FILENAME>", 1, 19);
		test::eq(ex(pp, HAS_INCLUDE, "__has_include", "#if __has_include(<a.h)"), "0\n");
		msg(d, 6, "expected closing '>'", 1, 24);
		msg(d, 7, "to match this '<'", 1, 19);
		check(d.messages.len(), 8);
		check(fake.calls, calls);
		check(pp.char_buf.len(), 0);
	};
}

fn void has_embed() @test
{
	@with_pp("x86_64-linux-gnu"; Compilation* comp, Diagnostics* d, Preprocessor* pp)
	{
		assert(@catch(expand_line(pp, HAS_EMBED, "__has_embed", "#if __has_embed(\"data.bin\")")) == aro::UNSUPPORTED);
		use_fake_files(pp);
		// [source] found and non-empty -> 1, empty -> 2, not found -> 0; limit 1.
		fake.embed_contents = "x";
		test::eq(ex(pp, HAS_EMBED, "__has_embed", "#if __has_embed(\"data.bin\")"), "1\n");
		test::eq(fake_name(), "data.bin");
		check(fake.limit, 1);
		check(fake.include_type.ordinal, IncludeType.QUOTES.ordinal);
		fake.embed_contents = "";
		test::eq(ex(pp, HAS_EMBED, "__has_embed", "#if __has_embed(<empty.bin> )"), "2\n");
		check(fake.include_type.ordinal, IncludeType.ANGLE_BRACKETS.ordinal);
		fake.embed_found = false;
		test::eq(ex(pp, HAS_EMBED, "__has_embed", "#if __has_embed(\"missing.bin\")"), "0\n");
		check(d.messages.len(), 0);
		// [source] embed parameters are plan 15's EmbedArgIterator.
		fake.embed_found = true;
		fake.embed_contents = "x";
		assert(@catch(expand_line(pp, HAS_EMBED, "__has_embed", "#if __has_embed(\"data.bin\" limit(1))")) == aro::UNSUPPORTED);
		// [source] outside #if; empty arguments; bad filename.
		test::eq(ex(pp, HAS_EMBED, "__has_embed", "int x = __has_embed(\"a\");", NON_EXPR), "1\n");
		msg(d, 0, "'__has_embed' must be used within a preprocessing directive", 1, 9);
		test::eq(ex(pp, HAS_EMBED, "__has_embed", "#if __has_embed()"), "0\n");
		msg(d, 1, "expected 1 argument(s) got 0", 1, 5);
		// a 1-byte "filename" is diagnosed as empty (length < 3).
		test::eq(ex(pp, HAS_EMBED, "__has_embed", "#if __has_embed(x)"), "0\n");
		msg(d, 2, "empty filename", 1, 17);
		// with embed args the scan stops after '>' (the rest are parameters).
		test::eq(ex(pp, HAS_EMBED, "__has_embed", "#if __has_embed(<a.h> )"), "1\n");
		test::eq(fake_name(), "a.h");
		check(d.messages.len(), 3);
	};
}

// ---------------------------------------------------------------------------
// _Pragma, __identifier, __pragma

fn void pragma_operator() @test
{
	@with_pp("x86_64-linux-gnu"; Compilation* comp, Diagnostics* d, Preprocessor* pp)
	{
		// [source] valid with NO_PRAGMA: nothing happens.
		test::eq(ex(pp, PRAGMA_OPERATOR, "_Pragma", "_Pragma(\"once\")", NO_PRAGMA), "");
		// [source] valid otherwise: plan 15 pragmaOperator.
		assert(@catch(expand_line(pp, PRAGMA_OPERATOR, "_Pragma", "_Pragma( \"once\" )", NON_EXPR)) == aro::UNSUPPORTED);
		check(d.messages.len(), 0);
		test::eq(ex(pp, PRAGMA_OPERATOR, "_Pragma", "_Pragma(\"a\" \"b\")"), "");
		msg(d, 0, "_Pragma requires exactly one string literal token", 1, 13);
		test::eq(ex(pp, PRAGMA_OPERATOR, "_Pragma", "x _Pragma((\"a\"))"), "");
		msg(d, 1, "_Pragma requires exactly one string literal token", 1, 11);
		test::eq(ex(pp, PRAGMA_OPERATOR, "_Pragma", "x _Pragma()"), "");
		msg(d, 2, "_Pragma requires exactly one string literal token", 1, 3);
		check(d.messages.len(), 3);
	};
}

fn void ms_identifier_and_pragma() @test
{
	@with_pp("x86_64-linux-gnu"; Compilation* comp, Diagnostics* d, Preprocessor* pp)
	{
		// [source] the argument becomes an IDENTIFIER (dupe; see the deviation note).
		test::eq(ex(pp, MS_IDENTIFIER, "__identifier", "int __identifier(int) = 1;", NON_EXPR), "ident:int");
		test::eq(ex(pp, MS_IDENTIFIER, "__identifier", "int __identifier( foo ) = 1;", NON_EXPR), "ident:foo");
		check(d.messages.len(), 0);
		// [fixture msvc macros.c:10:16, 9:14, 8:1]
		test::eq(ex(pp, MS_IDENTIFIER, "__identifier", "__identifier(a b)", NON_EXPR), "");
		msg(d, 0, "missing ')', after identifier", 1, 16);
		test::eq(ex(pp, MS_IDENTIFIER, "__identifier", "__identifier(1)", NON_EXPR), "");
		msg(d, 1, "cannot convert a number to an identifier", 1, 14);
		test::eq(ex(pp, MS_IDENTIFIER, "__identifier", "__identifier()", NON_EXPR), "");
		msg(d, 2, "expected identifier argument", 1, 1);
		check(d.messages.len(), 3);
		// [source] __pragma(): unknown_pragma is off by default; otherwise plan 15.
		test::eq(ex(pp, MS_PRAGMA, "__pragma", "__pragma()", NON_EXPR), "");
		check(d.messages.len(), 3);
		assert(@catch(expand_line(pp, MS_PRAGMA, "__pragma", "__pragma(once)", NON_EXPR)) == aro::UNSUPPORTED);
	};
}
