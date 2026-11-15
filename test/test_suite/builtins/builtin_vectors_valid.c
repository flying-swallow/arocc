// #opt: --target=x86_64-linux-gnu -Wno-unused
// Source-derived from test/cases/convertvector.c and
// test/cases/shufflevector.c; only their valid vector operations are retained.
/** manifest:
syntax
args = --target=x86_64-linux-gnu -Wno-unused
*/
typedef int i2v __attribute__((__vector_size__(sizeof(int) * 2)));
typedef int i4v __attribute__((__vector_size__(sizeof(int) * 4)));
typedef float f2v __attribute__((__vector_size__(sizeof(float) * 2)));

void vector_builtins(i2v a, i2v b) {
	i4v shuffled4 = __builtin_shufflevector(a, b, 0, 1, 2, 3);
	i2v shuffled2 = __builtin_shufflevector(a, b, -1, 3);
	f2v converted = __builtin_convertvector(a, f2v);
}
