// Sema contract stubs for c3c src/compiler/methodtable.c (revision 54bab366a): every function
// of the C file not ported yet, with its final C3 signature and an
// `unreachable` body, in c3c order. Port each body in place (see
// PORTING.md "Sema contract"); the `// file:line` comment points at the
// c3c definition and marks static functions.
module aro::frontend::c3::compiler;
import aro::frontend::c3::tokens;

// methodtable.c:3 (static)
fn DeclId* methodentry_find(DeclId* entries, uint capacity, String name, Type* type)
{
	unreachable("sema stub: methodentry_find");
}

// methodtable.c:20 (static)
fn void methodtable_resize(MethodTable* table)
{
	unreachable("sema stub: methodtable_resize");
}

// methodtable.c:42
fn DeclId methodtable_set(MethodTable* table, Decl* decl)
{
	unreachable("sema stub: methodtable_set");
}

// methodtable.c:57
fn DeclId methodtable_get(MethodTable* table, Type* type, String name)
{
	unreachable("sema stub: methodtable_get");
}

// methodtable.c:64
fn void methodtable_init(MethodTable* table, uint initial_size)
{
	unreachable("sema stub: methodtable_init");
}
