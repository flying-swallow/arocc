// #kind: run
// #exit: 0
// Linear function test replacement: once strength reduction gives the loop a
// pointer IV, the `i < hi` exit becomes `p != start + max(hi - lo, 0) * 4`.
// Runtime bounds cover empty (lo == hi), reversed (lo > hi), inclusive (<=)
// and negative-start ranges, plus a `>` compare written bound-first.

__attribute__((noinline)) static long half_open(const int *a, int off, int lo, int hi)
{
    long s = 0;
    for (int i = lo; i < hi; i++) s += a[i + off];
    return s;
}

__attribute__((noinline)) static long closed(const int *a, int off, int lo, int hi)
{
    long s = 0;
    for (int i = lo; i <= hi; i++) s += a[i + off];
    return s;
}

__attribute__((noinline)) static long bound_first(const int *a, int off, int lo, int hi)
{
    long s = 0;
    for (int i = lo; hi > i; i++) s += a[off + i] * 3;
    return s;
}

static long ref_sum(const int *a, int off, int lo, int end)
{
    long s = 0;
    for (int i = lo; i < end; i++) s += a[i + off];
    return s;
}

int main(void)
{
    int a[100];
    for (int i = 0; i < 100; i++) a[i] = i * i - 7 * i;
    int cases[][3] = { { 10, 0, 40 }, { 10, 5, 5 }, { 10, 30, 20 }, { 50, -20, 30 }, { 0, 0, 1 }, { 60, -60, 39 } };
    for (unsigned c = 0; c < sizeof cases / sizeof cases[0]; c++)
    {
        int off = cases[c][0], lo = cases[c][1], hi = cases[c][2];
        if (half_open(a, off, lo, hi) != ref_sum(a, off, lo, hi)) return 1 + (int)c;
        if (closed(a, off, lo, hi) != ref_sum(a, off, lo, hi + 1)) return 11 + (int)c;
        if (bound_first(a, off, lo, hi) != 3 * ref_sum(a, off, lo, hi)) return 21 + (int)c;
    }
    return 0;
}
