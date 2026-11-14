/** manifest:
syntax
*/
int choose_value(void) {
	return __builtin_choose_expr(1, 2, 3);
}
