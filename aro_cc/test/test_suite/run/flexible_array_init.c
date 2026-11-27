// #kind: run
// #exit: 0
/* GNU static initializers for a trailing flexible array member extend the
   object (gcc.c-torture/execute/20010924-1.c): string, brace list, designator,
   and an absent initializer. Returns a failure bitmask. */
struct C { char c; char p[]; };
struct C a3 = { 'o', "wx" };
struct C a4 = { '9', { 'e', 'b' } };
struct I { int c; int p[]; } a5 = { 1, { [3] = 7 } };
struct C a6 = { 1 };
struct D { double d; char p[]; } a7 = { 1.0, "abc" };
int after = 42;

int main(void)
{
	int fail = 0;
	if (a3.c != 'o' || a3.p[0] != 'w' || a3.p[1] != 'x' || a3.p[2] != 0) fail |= 1;
	if (a4.c != '9' || a4.p[0] != 'e' || a4.p[1] != 'b') fail |= 2;
	if (a5.c != 1 || a5.p[0] != 0 || a5.p[2] != 0 || a5.p[3] != 7) fail |= 4;
	if (a6.c != 1) fail |= 8;
	if (a7.d != 1.0 || a7.p[0] != 'a' || a7.p[2] != 'c' || a7.p[3] != 0) fail |= 16;
	if (after != 42) fail |= 32;
	return fail;
}
