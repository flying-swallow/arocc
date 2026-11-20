// #kind: run
// #exit: 0
/* `!` pushed through conditions by De Morgan, and GNU `c ?: e` yielding c's
   own value (not its truth). Returns a failure bitmask. */
int elvis(int x, int y) { return x ?: y; }
int elvis_not(int x, int y) { return !x ?: y; }
int elvis_not_or(int x, int y) { return !(x || y) ?: 7; }
int elvis_and(int x, int y) { return (x && y) ?: 7; }
int not_less(double d, double e) { return !(d < e); }
int not_cond(int a, int b, int c) { return !(a ? b : c); }
int not_elvis(int a, int b) { return !(a ?: b); }
int stmt(int a, int b)
{
	if (!(a && !b)) return 1;
	return 0;
}

int main(void)
{
	int fail = 0;
	double nan = __builtin_nan("");
	if (not_less(nan, 1.0) != 1) fail |= 1;
	if (not_less(0.0, 1.0) != 0 || not_less(2.0, 1.0) != 1) fail |= 1;
	for (int a = 0; a < 3; a++)
		for (int b = 0; b < 2; b++)
			for (int c = 0; c < 2; c++)
			{
				int at = a != 0;
				if (elvis(a, b) != (at ? a : b)) fail |= 2;
				if (elvis_not(a, b) != (at ? b : 1)) fail |= 4;
				if (elvis_not_or(a, b) != (at + b ? 7 : 1)) fail |= 8;
				if (elvis_and(a, b) != (at * b ? 1 : 7)) fail |= 16;
				if (not_cond(a, b, c) != 1 - (at ? b : c)) fail |= 32;
				if (not_elvis(a, b) != (at ? 0 : 1 - b)) fail |= 64;
				if (stmt(a, b) != 1 - at * (1 - b)) fail |= 128;
			}
	return fail;
}
