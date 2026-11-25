// #kind: run
// #exit: 0
// `x op= y` evaluates y before reading x, as gcc does (PR c/58943), so writes
// to x made while evaluating y are seen; also for bitfields and pointers.
unsigned x = 2;
unsigned foo(void) { x |= 128; return 1; }

struct S { unsigned f : 8; unsigned g : 8; } s = { 2, 0 };
unsigned bar(void) { s.f += 16; return 1; }

int arr[8];
int *p = arr;
long step(void) { p += 2; return 1; }

long shift = 1;
int amount(void) { shift = 4; return 2; }

int main(void)
{
	x |= foo();
	if (x != 131) return 1;
	s.f += bar();
	if (s.f != 19) return 2;
	p += step();
	if (p != arr + 3) return 3;
	shift <<= amount();
	if (shift != 16) return 4;
	int i = 0;
	int a[4] = { 1, 2, 3, 4 };
	a[i++] += 10;              /* lhs subscript still evaluated once */
	if (i != 1 || a[0] != 11) return 5;
	return 0;
}
