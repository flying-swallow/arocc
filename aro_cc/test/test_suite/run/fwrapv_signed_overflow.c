// #kind: run
// #opt: -O2 -fwrapv
// #exit: 0
// -fwrapv makes signed overflow wrap: codegen sets no `nsw`, so the optimizer
// must not widen or reassociate this arithmetic as if it could not overflow.

__attribute__((noinline)) static int bump(int x, int k)
{
    return (x + 2147483647) + k;
}

__attribute__((noinline)) static long sum_wrapped(const int *mid, int start, int n)
{
    long s = 0;
    // start + i wraps from INT_MAX to INT_MIN; the + (-2147483647 - 1) brings it back near 0.
    for (int i = 0; i < n; i++) s += mid[(start + i) + (-2147483647 - 1)];
    return s;
}

int main(void)
{
    if (bump(1, 1) != -2147483647) return 1;
    int a[16];
    for (int i = 0; i < 16; i++) a[i] = i + 1;
    // start = INT_MAX - 3: indices wrap to -4..3 relative to a + 8.
    long s = sum_wrapped(a + 8, 2147483647 - 3, 8);
    if (s != 5 + 6 + 7 + 8 + 9 + 10 + 11 + 12) return 2;
    return 0;
}
