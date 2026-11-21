// #kind: run
// #exit: 0
// sizeof/alignof whose value is discarded or sits in a comma operand: glibc
// assert expands to `((void) sizeof ((expr) ? 1 : 0), ...)`.
#include <assert.h>

static int calls;
static int bump(void) { return ++calls; }

int main(int argc, char **argv) {
    (void)argv;
    (void) sizeof (argc ? 1 : 0);
    (void) _Alignof(double);
    assert(argc > 0);
    int a = ((void)sizeof(long), 3);
    unsigned long b = (bump(), sizeof(int[4]));
    (void) sizeof (bump());  /* operand is not evaluated */
    if (a != 3 || b != 16 || calls != 1) return 1;
    return 0;
}
