/* A folded (non-literal) integer constant expression cast to a pointer is an
   address constant (C11 6.6p9) in static initializers, global or static local
   (sqlite JFUNCTION: SQLITE_INT_TO_PTR(iArg|((bJsonB)*JSON_BLOB))). */
#define BLOB 0x10
#define INT_TO_PTR(X) ((void*)(__PTRDIFF_TYPE__)(X))
static void *g = INT_TO_PTR(0|((1)*BLOB));
static void *h = (void *)(2 + 3);
struct F { int n; void *p; const char *z; };
static struct F gf[] = { { 1, INT_TO_PTR(0|((0)*BLOB)), "json" }, { 1, INT_TO_PTR(0|((1)*BLOB)), "jsonb" } };
void reg(void)
{
	static struct F a[] = {
		{ 1, INT_TO_PTR(0|((0)*BLOB)), "json" },
		{ 1, INT_TO_PTR(8|((1)*BLOB)), "jsonb" },
	};
	(void)a;
}
