// #kind: run
// #opt: -O2
// #exit: 0

// F32/F64 values held in XMM registers: live across calls (all XMM registers
// are caller-saved), more live values than registers, x87 conversions, loop
// PHIs, and float arguments passed on the stack.
static volatile double sink;

__attribute__((noinline)) double opaque(double x) { sink = x; return x * 0.5; }
__attribute__((noinline)) float opaque_f(float x) { sink = x; return x + 1.0f; }

__attribute__((noinline)) double many_args(double a, double b, double c, double d, double e,
	double f, double g, double h, double i, double j, float k)
{
	return a + 2 * b + 3 * c + 4 * d + 5 * e + 6 * f + 7 * g + 8 * h + 9 * i + 10 * j + 11 * k;
}

__attribute__((noinline)) double across_calls(double x)
{
	double a = x + 1, b = x * 2, c = x - 3, d = x / 4;
	double e = opaque(a);
	double f = opaque(b * b + 1);
	return a + b + c + d + e + f;
}

__attribute__((noinline)) double pressure(double x)
{
	double v0 = x + 1, v1 = x + 2, v2 = x + 3, v3 = x + 4, v4 = x + 5, v5 = x + 6;
	double v6 = x + 7, v7 = x + 8, v8 = x + 9, v9 = x + 10, v10 = x + 11, v11 = x + 12;
	double s = opaque(v0 * v11);
	return s + v0 * v1 + v2 * v3 + v4 * v5 + v6 * v7 + v8 * v9 + v10 * v11 + v0 + v11;
}

__attribute__((noinline)) double loop_phis(int n)
{
	double sum = 0, prod = 1;
	float fs = 0;
	for (int i = 1; i <= n; i++)
	{
		sum += 1.0 / i;
		prod *= 1.0 + 1.0 / (i * i);
		fs += opaque_f((float)i);
	}
	return sum + prod + fs;
}

__attribute__((noinline)) double via_long_double(double x, float y)
{
	long double wide = (long double)x * 3 + y;
	double back = (double)wide;
	float narrow = (float)wide;
	return back + narrow + x;
}

static double absd(double v) { return v < 0 ? -v : v; }
static int close(double a, double b) { return absd(a - b) <= 1e-9 * (absd(b) + 1); }

int main(void)
{
	int fail = 0;
	if (!close(many_args(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11.0f), 506)) fail |= 1;
	if (!close(across_calls(5), 6 + 10 + 2 + 1.25 + 3 + 50.5)) fail |= 2;
	double x = 2;
	double expect = (x + 1) * (x + 12) * 0.5 + (x + 1) * (x + 2) + (x + 3) * (x + 4) + (x + 5) * (x + 6) +
		(x + 7) * (x + 8) + (x + 9) * (x + 10) + (x + 11) * (x + 12) + (x + 1) + (x + 12);
	if (!close(pressure(x), expect)) fail |= 4;
	double sum = 0, prod = 1, fs = 0;
	for (int i = 1; i <= 50; i++) { sum += 1.0 / i; prod *= 1.0 + 1.0 / (i * i); fs += (float)i + 1.0f; }
	if (!close(loop_phis(50), sum + prod + fs)) fail |= 8;
	if (!close(via_long_double(1.5, 0.25f), (1.5 * 3 + 0.25) * 2 + 1.5)) fail |= 16;
	return fail;
}
