// #kind: run
// #exit: 0
/* Global aggregate initializers: arrays with designators and fillers, string
   arrays, structs with pointer/function relocations, bitfields, nested records,
   address constants and integer-to-pointer constants. Returns a failure bitmask. */
#include <stddef.h>
int helper(int x) { return x * 2; }
typedef int (*fnp)(int);
int glob = 7;
int arr[5] = { 1, 2, 3 };
int arr2[] = { [3] = 9, [1] = 4 };
char str[8] = "hey";
const char *names[] = { "zero", "one", "two" };
struct P { char tag; int v; long w; const char *s; int (*fn)(int); } ps[] = {
	{ 'a', 1, 100, "first", helper },
	{ .v = 2, .s = "second" },
};
struct B { unsigned a : 3; unsigned b : 5; int c; } bits = { 5, 17, -3 };
int *pg = &glob;
int *parr = &arr[2];
void *pint = (void *)(long)(16);
struct N { struct P p; int m[2][2]; } nested = { { 'z', 9, 0, "n", 0 }, { { 1, 2 }, { 3, 4 } } };
static int lookup[256] = { [0] = 1, [255] = 2 };
static unsigned sum_bytes(const void *p, unsigned long n, unsigned long skip_lo, unsigned long skip_n)
{
	const unsigned char *b = p;
	unsigned s = 0;
	for (unsigned long i = 0; i < n; i++)
		if (i < skip_lo || i >= skip_lo + skip_n) s = s * 31 + b[i];
	return s;
}
#define FIELD(base, T, type, f) (*(type *)((char *)(base) + offsetof(T, f)))
int main(void)
{
	int ok = 0;
	ok += sum_bytes(arr, sizeof arr, 0, 0) == sum_bytes((int[5]){ 1, 2, 3, 0, 0 }, 20, 0, 0) ? 0 : 1;
	ok += (arr2[3] == 9 && arr2[1] == 4 && arr2[0] == 0 && sizeof(arr2) == 16) ? 0 : 2;
	ok += (str[0] == 'h' && str[2] == 'y' && str[3] == 0 && str[7] == 0) ? 0 : 4;
	ok += (names[2][1] == 'w' && names[0][0] == 'z') ? 0 : 8;
	char *p0 = (char *)&ps[0];
	char *p1 = (char *)&ps[1];
	ok += (FIELD(p0, struct P, char, tag) == 'a' && FIELD(p0, struct P, int, v) == 1 && FIELD(p0, struct P, long, w) == 100) ? 0 : 16;
	ok += (FIELD(p0, struct P, fnp, fn) == helper && FIELD(p0, struct P, const char *, s)[1] == 'i') ? 0 : 32;
	ok += (FIELD(p1, struct P, int, v) == 2 && FIELD(p1, struct P, char, tag) == 0 && FIELD(p1, struct P, const char *, s)[0] == 's') ? 0 : 64;
	unsigned char *bb = (unsigned char *)&bits;
	ok += (bb[0] == (5 | (17 << 3)) && *(int *)(bb + 4) == -3) ? 0 : 128;
	ok += (*pg == 7 && *parr == 3 && (long)pint == 16) ? 0 : 256;
	char *np = (char *)&nested;
	int *m = (int *)(np + offsetof(struct N, m));
	ok += (FIELD(np, struct P, int, v) == 9 && m[2] == 3 && m[3] == 4) ? 0 : 512;
	ok += (lookup[0] == 1 && lookup[255] == 2 && lookup[100] == 0) ? 0 : 1024;
	return ok;
}
