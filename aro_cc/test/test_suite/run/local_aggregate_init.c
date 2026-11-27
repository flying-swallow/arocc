// #kind: run
// #exit: 0
/* Local aggregate initializers: zero-fill plus element stores, designators,
   string-initialized char arrays, structs, nested arrays, compound literals.
   Returns a failure bitmask. */
#include <stddef.h>
static int sum(const int *v, int n) { int s = 0; for (int i = 0; i < n; i++) s += v[i]; return s; }
static int len(const char *s) { int n = 0; while (s[n]) n++; return n; }
struct P { char tag; int v; long w; const char *s; };
#define FIELD(base, T, type, f) (*(type *)((char *)(base) + offsetof(T, f)))
int main(int argc, char **argv)
{
	(void)argv;
	int ok = 0;
	int a[5] = { 1, 2, argc + 2 };                 /* 1+2+3 */
	ok += sum(a, 5) == 6 ? 0 : 1;
	int b[] = { [4] = 7, [1] = argc };
	ok += (sizeof b == 20 && sum(b, 5) == 8 && b[0] == 0 && b[2] == 0) ? 0 : 2;
	char s[16] = "hello";
	ok += (len(s) == 5 && s[15] == 0) ? 0 : 4;
	char t[3] = "abc";
	ok += (t[2] == 'c') ? 0 : 8;
	const char *names[] = { "x", "yy", "zzz" };
	ok += (len(names[0]) + len(names[1]) + len(names[2]) == 6) ? 0 : 16;
	struct P p = { 'q', argc * 5, 1000, "str" };
	ok += (FIELD(&p, struct P, char, tag) == 'q' && FIELD(&p, struct P, int, v) == 5 &&
		FIELD(&p, struct P, long, w) == 1000 && FIELD(&p, struct P, const char *, s)[2] == 'r') ? 0 : 32;
	struct P q = { .s = "z" };
	ok += (FIELD(&q, struct P, int, v) == 0 && FIELD(&q, struct P, long, w) == 0) ? 0 : 64;
	int big[100] = { [50] = argc, [99] = 2 };
	ok += (sum(big, 100) == 3) ? 0 : 128;
	int m[2][3] = { { 1, 2, 3 }, { 4 } };
	ok += (sum(&m[0][0], 6) == 10 && m[1][2] == 0) ? 0 : 256;
	ok += sum((int[]){ 4, 5, 6 }, 3) == 15 ? 0 : 512;
	for (int i = 0; i < 3; i++) { int r[4] = { i }; ok += r[0] == i && r[3] == 0 ? 0 : 1024; r[3] = 9; }
	return ok;
}
