/** manifest:
syntax

first argument to va_arg is of type int and not 'va_list'
*/
int va_arg_with_non_va_list(void) {
	return __builtin_va_arg(1, int);
}
