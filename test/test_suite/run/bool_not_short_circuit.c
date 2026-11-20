// #kind: run
// #exit: 0
/* `!` inside a short-circuit chain used as a value: the last operand's
   compare flows straight into the phi and must be inverted, and a nested
   chain (call argument) must not inherit the outer inversion
   (gcc.c-torture/execute/961122-2.c). Returns a failure bitmask. */
int id(int x) { return x; }
int f1(int a) { return (a >= 0 && a <= 10) && !(a >= 0); }
int f2(int a, int b, int c) { return a && !(b && c); }
int f3(int a, int b) { return a || !(b || a); }
int f4(int a, int b) { return a && !id(b && a); }
int f5(int a, int b) { return a && !(b ? a : b); }
int f6(int a, int b) { return a && !!b; }
int f7(int a, int b) { return !(a && b); }

int main(void)
{
	int fail = 0;
	for (int a = 0; a < 2; a++)
		for (int b = 0; b < 2; b++)
			for (int c = 0; c < 2; c++)
			{
				if (f1(a + b - 1) != 0) fail |= 1;
				if (f2(a, b, c) != a * (1 - b * c)) fail |= 2;
				if (f3(a, b) != a + (1 - a) * (1 - b)) fail |= 4;
				if (f4(a, b) != a * (1 - b)) fail |= 8;
				if (f5(a, b) != a * (1 - b)) fail |= 16;
				if (f6(a, b) != a * b) fail |= 32;
				if (f7(a, b) != 1 - a * b) fail |= 64;
			}
	return fail;
}
