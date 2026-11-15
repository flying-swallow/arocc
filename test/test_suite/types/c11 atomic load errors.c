typedef void *aligned_ptr __attribute__((aligned(16)));
void test(const int *i, const aligned_ptr *p, void *v) {
    __c11_atomic_load(i, 5); // #error@23: address argument to atomic operation must be a pointer to _Atomic type ('const int *' invalid)
    void *q = __c11_atomic_load(p, 5); // #error@33: address argument to atomic operation must be a pointer to _Atomic type ('const aligned_ptr *' (aka 'void *const*') invalid)
    __c11_atomic_load(v, 5); // #error@23: address argument to atomic operation must be a pointer to _Atomic type ('void *' invalid)
    __c11_atomic_load(1, 5); // #error@23: address argument to atomic builtin must be a pointer ('int' invalid)
}

