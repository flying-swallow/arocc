// #kind: run
// #exit: 0
// #opt: -w
// A K&R definition is not a prototype: `float` (and narrow integer) parameters
// are passed default-promoted, so callers send a double and the callee narrows
// it on entry (gcc.c-torture/execute/930603-1.c).
float fx(x) float x; { return x * 2; }
double mix(a, b, c) float a; short b; float c; { return a + b + c; }
int main(void)
{
	float (*unprototyped)() = fx;
	if (fx(4.0f) != 8.0f) return 1;
	if (unprototyped(1.5f) != 3.0f) return 2;
	if (mix(0.25f, 3, 0.5f) != 3.75) return 3;
	return 0;
}
