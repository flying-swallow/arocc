/* A string literal initializes a pointer element, not the whole array, when the
   array's element type is not a character type (Zig isStringInit; sqlite
   `static const char * const sqlite3azCompileOpt[] = { "A=" CTIMEOPT_VAL(X), ... }`). */
#define VAL_(o) #o
#define VAL(o) VAL_(o)
#define OPT 1
static const char *const a[] = { "x", "yy" };
const char *b[] = { "AB=" VAL(OPT), "C", };
char *const c[2] = { "p" };
_Static_assert(sizeof(a) == 2 * sizeof(char *), "a");
_Static_assert(sizeof(b) == 2 * sizeof(char *), "b");
char d[] = "hey";
unsigned char e[4] = "ab";
char g[2][3] = { "ab", "cd" };
struct S { char n[4]; int v; } s[] = { "abc", 1, "de", 2 };
_Static_assert(sizeof(s) == 2 * sizeof(struct S), "s");
void f(void)
{
	const char *const l[] = { "x", "yy" };
	(void)l;
}
