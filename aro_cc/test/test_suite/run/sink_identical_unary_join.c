// #kind: run
// #exit: 0
// #opt: -O1
// simplify_cfg sinks an expression computed identically on both arms into the
// join; a unary one (no rhs) must not try to build a PHI for its missing operand
// (csmith seed 307 crashed the compiler).
static int calls;
__attribute__((noinline)) static void left(void) { calls += 1; }
__attribute__((noinline)) static void right(void) { calls += 10; }
__attribute__((noinline)) static long both_arms(int c, int x)
{
	long r;
	if (c) { left(); r = -(long)x; } else { right(); r = -(long)x; }
	return r;
}
__attribute__((noinline)) static unsigned both_not(int c, unsigned x)
{
	unsigned r;
	if (c > 3) { left(); r = ~x; } else { right(); r = ~x; }
	return r;
}
int main(void)
{
	if (both_arms(1, 5) != -5 || both_arms(0, 7) != -7) return 1;
	if (both_not(9, 0) != ~0u || both_not(0, 1) != ~1u) return 2;
	return calls == 22 ? 0 : 3;
}
