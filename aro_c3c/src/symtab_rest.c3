// Port of the symtab.c functions not covered by symtab_globals.c3 /
// symtab.c3 (c3c revision 54bab366a).
// Companion of symtab_globals.c3 / tables.c3 (symtab.c).
//
// Deviations from c3c:
// - The symbol table is `global_symtab` (symtab::Symtab), so `symtab_destroy`
//   frees it instead of c3c's bucket array.
module aro::frontend::c3::compiler;
import aro::frontend::c3::tokens;

// symtab.c:105
fn void symtab_destroy()
{
	global_symtab.free();
}
