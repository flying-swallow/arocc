// #kind: run
// #exit: 0
// csmith pattern: an index computed in wrapping unsigned arithmetic and then
// converted to int is not `nsw`, so `indvar_widen` must keep its sign extension:
// (int)(0xFFFFFFFFu * i) is -i, a backwards walk from the middle of the array.

__attribute__((noinline)) static long walk(const int *mid, unsigned u, int n)
{
    long s = 0;
    for (int i = 0; i < n; i++) s += mid[(int)(u * (unsigned)i)] * (long)(i + 1);
    return s;
}

__attribute__((noinline)) static long walk_sum(const int *mid, unsigned u, int n)
{
    long s = 0;
    for (int i = 0; i < n; i++) s += mid[(int)(u + (unsigned)i)];
    return s;
}

int main(void)
{
    int a[64];
    for (int i = 0; i < 64; i++) a[i] = i * 5 - 100;
    long expect = 0;
    for (int i = 0; i < 20; i++) expect += a[32 - i] * (long)(i + 1);
    if (walk(a + 32, 0xFFFFFFFFu, 20) != expect) return 1;
    long expect_sum = 0;
    for (int i = 0; i < 20; i++) expect_sum += a[32 - 10 + i];
    if (walk_sum(a + 32, (unsigned)-10, 20) != expect_sum) return 2;
    return 0;
}
