// Source-derived from test/cases/builtin choose expr.c: the unselected arm
// may contain an invalid operation without being evaluated.
/** manifest:
syntax
*/
void choose_expr_unevaluated(void) {
	int x, y;
	__builtin_choose_expr(1, x, 0 / 0) = 10;
	__builtin_choose_expr(0, x / 0, y) = 32;
}
