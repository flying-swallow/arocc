// #opt: -std=c17 -target x86_64-linux
typedef int __attribute__((vector_size(16))) v4si;
typedef int __attribute__((vector_size(8))) v2si;
typedef float __attribute__((vector_size(16))) v4sf;
v4si a, b; v2si c; v4sf f;
void t1(void) { a = a + b; }
void t2(void) { a = a % b; }
void t3(void) { a %= b; }
void t4(void) { a <<= b; }
void t5(void) { a = a + 1; }
void t6(void) { a = 2 * a; }
void t7(void) { a = a == b; }
void t8(void) { a = f < f; }
void t9(void) { a = a + c; } // #error@23: cannot convert between vector type 'v4si' (vector of 4 'int' values) and vector type 'v2si' (vector of 2 'int' values) as implicit conversion would cause truncation
void t10(void) { a = a && b; } // #error@24: invalid operands to binary expression ('v4si' (vector of 4 'int' values) and 'v4si' (vector of 4 'int' values))
