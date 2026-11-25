// #kind: run
// #exit: 0
// `int main` returns 0 when control reaches its closing brace, also when the
// last statement is a loop (C99 5.1.2.2.3); EAX must not keep a stale value.
int g;
__attribute__((noinline)) static int f(int x) { return x + 5; }
int main(void)
{
	for (int i = 0; i < 3; i++)
		g = f(i);
}
