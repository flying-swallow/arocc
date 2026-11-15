// #error: first argument to __builtin_convertvector must be a vector type
/** manifest:
syntax

first argument to __builtin_convertvector must be a vector type
*/
int convertvector_with_non_vector(void) {
	return __builtin_convertvector(1, int);
}
