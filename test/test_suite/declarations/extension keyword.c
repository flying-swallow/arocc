/* `__extension__` before a declaration at file scope, block scope and in a
   record (Zig rootItem / compoundStmtItem / recordDeclItem; glibc
   `__extension__ typedef struct { long long int quot; ... } lldiv_t;` and
   `__extension__ extern int ffsll (long long int)`). */
__extension__ typedef struct { long long quot, rem; } lldiv_like;
__extension__ extern int ffsll_like(long long);
__extension__ __extension__ static int twice;
__extension__;
struct S
{
	__extension__ long long a;
	__extension__ union { int b; float c; };
	int d;
};
int f(void)
{
	__extension__ long long x = 1;
	__extension__ typedef int T;
	T y = 0;
	return (int)x + y + __extension__ 0 + twice;
}
