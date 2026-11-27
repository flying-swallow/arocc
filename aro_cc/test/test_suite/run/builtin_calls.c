// #kind: run
// #exit: 0
// Builtins lowered by CodeGen.gen_builtin_call: libc forwarding, expect,
// prefetch, bswap and non-folded object_size.
typedef unsigned long size_t;

static int size_of(char *p, int kind) {
    return __builtin_object_size(p, 0) == (size_t)-1 && __builtin_object_size(p, 2) == 0 ? kind : -1;
}

int main(void) {
    char a[16];
    char b[16];
    __builtin_memset(a, 'x', 15);
    *(a + 15) = 0;
    __builtin_memcpy(b, a, 16);
    if (__builtin_memcmp(a, b, 16) != 0) __builtin_abort();
    if (__builtin_strlen(b) != 15) __builtin_abort();
    if (__builtin_strcmp(a, b) != 0) __builtin_abort();
    if (__builtin_expect(__builtin_strlen(a), 15) != 15) __builtin_abort();
    __builtin_prefetch(a);
    if (__builtin_bswap16(0x1234) != 0x3412) __builtin_abort();
    unsigned int w = 0x11223344;
    if (__builtin_bswap32(w) != 0x44332211u) __builtin_abort();
    unsigned long long q = 0x0102030405060708ULL;
    if (__builtin_bswap64(q) != 0x0807060504030201ULL) __builtin_abort();
    if (__builtin_ffs(w) != 3) __builtin_abort();
    if (size_of(a, 7) != 7) __builtin_abort();
    __builtin_printf("ok %d\n", 1);
    return 0;
}
