int v;
static void *bad = (void *)(long)v; // #error: initializer element is not a compile-time constant
