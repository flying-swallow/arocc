// Tests for the c3 frontend AST arenas, ids and vectors (ast.c3, vmem.c3).
module c3_ast_tests @test;
import aro::frontend::c3::compiler, aro::frontend::c3::tokens;

fn void ids_round_trip()
{
	defer compiler::ast_memory_reset();
	Expr* e = compiler::expr_calloc();
	Expr* f = compiler::expr_calloc();
	ExprId id = compiler::exprid(e);
	assert(id == 1);
	assert(compiler::exprid(f) == 2);
	assert(compiler::exprptr(id) == e);
	assert(compiler::exprptrzero(0) == null);
	Decl* d = compiler::decl_calloc();
	assert(compiler::declptr(compiler::declid(d)) == d);
	assert(d.name.len == 0 && d.decl_kind == DeclKind.POISONED);
}

fn void locations()
{
	defer compiler::ast_memory_reset();
	SourceSpan a = { .file_id = 1, .row = 2, .col = 3, .offset = 10, .length = 2 };
	SourceSpan b = { .file_id = 1, .row = 2, .col = 9, .offset = 16, .length = 3 };
	SourceLocId id = compiler::make_loc(a);
	assert(id != compiler::INVALID_LOC);
	SourceSpan c = compiler::extend_loc_with_token(compiler::sourcelocptr(id), &b);
	assert(c.offset == 10 && c.length == 9 && c.col == 3);
	SourceLocId copy = compiler::copy_loc(id);
	assert(copy != id && compiler::sourcelocptr(copy).offset == 10);
}

fn void vectors_grow()
{
	defer compiler::ast_memory_reset();
	Decl*[] list;
	Decl*[] seen;
	for (int i = 0; i < 100; i++)
	{
		Decl* d = compiler::decl_calloc();
		compiler::@vec_add(&list, d);
		compiler::@vec_add(&seen, d);
	}
	assert(list.len == 100);
	foreach (i, d : list) assert(d == seen[i]);
	Decl* last = compiler::@vec_pop(&list);
	assert(last == seen[99] && list.len == 99);
	compiler::@vec_erase_front(&list, 2);
	assert(list.len == 97 && list[0] == seen[2]);
	compiler::@vec_erase_at(&list, 0);
	assert(list[0] == seen[3]);
}

fn void enum_ranges()
{
	assert(compiler::TYPE_INTEGER_FIRST == TypeKind.I8);
	assert(compiler::TYPE_INTEGER_LAST == TypeKind.U128);
	assert(compiler::SCOPE_MACRO == 1 << 4);
}
