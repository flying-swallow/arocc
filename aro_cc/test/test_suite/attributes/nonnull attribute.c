// #skip: diagnostics differ (aro_cc gap)
void plain_nonnull(int *a, int b, char *c) __attribute__((nonnull));
void nonnull_with_args(int *a, int *b, int c) __attribute__((nonnull(2, 1)));

void caller(void) {
    plain_nonnull(0, 1, 0); // #warning@19: null passed to a callee that requires a non-null argument [-Wnonnull] // #warning@25: null passed to a callee that requires a non-null argument [-Wnonnull]
    nonnull_with_args(0, 0, 1); // #warning@23: null passed to a callee that requires a non-null argument [-Wnonnull] // #warning@26: null passed to a callee that requires a non-null argument [-Wnonnull]
}

