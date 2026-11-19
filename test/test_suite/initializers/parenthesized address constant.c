/* Parentheses are transparent for static-initializer constness
   (sqlite SQLITE_INT_TO_PTR: `((void*)(intptr_t)(X))`). */
static void *p = (void *)(2);
static void *q = ((void *)2);
static void *r = (void *)(long)(3);
int x;
static int *s = (&x);
struct T { void *a; const char *n; } t[] = { { (void *)(long)(1), "n" } };
