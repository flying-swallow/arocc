// #kind: run
// #exit: 0
// `indvar_widen` + `loop_strength_reduce`: int indices reach addresses as
// `sext (op nsw i32)`, get i64 IV twins, and affine addresses become stepped
// pointer PHIs. Covers runtime strides, negative offsets, down-counting and
// stepped IVs, a pointer-difference index, and an IV used after its loop.

__attribute__((noinline)) static void mm(int *a, int *b, int *c, int n)
{
    for (int i = 0; i < n; i++)
        for (int j = 0; j < n; j++)
        {
            int sum = 0;
            for (int k = 0; k < n; k++) sum += a[i * n + k] * b[k * n + j];
            c[i * n + j] = sum;
        }
}

__attribute__((noinline)) static long down(const int *a, int n, int stride)
{
    long s = 0;
    for (int i = n - 1; i >= 0; i -= 2) s += a[i * stride - 1 + stride] * (long)(i + 1);
    return s;
}

__attribute__((noinline)) static int last_index(const int *a, int n, int target)
{
    int i;
    for (i = 0; i < n; i++)
        if (a[3 * i + 1] == target) break;
    return i;
}

__attribute__((noinline)) static long window(const short *p, int base, int len)
{
    long s = 0;
    for (int k = -len; k <= len; k++) s += p[base + k] * (k + 7);
    return s;
}

int main(void)
{
    enum { N = 7 };
    int a[N * N], b[N * N], c[N * N];
    for (int i = 0; i < N * N; i++)
    {
        a[i] = (i * 7 + 3) % 11 - 5;
        b[i] = (i * 13 + 5) % 9 - 4;
    }
    mm(a, b, c, N);
    long check = 0;
    for (int i = 0; i < N; i++)
        for (int j = 0; j < N; j++)
        {
            int ref = 0;
            for (int k = 0; k < N; k++) ref += a[i * N + k] * b[k * N + j];
            if (c[i * N + j] != ref) return 1;
            check = check * 31 + c[i * N + j];
        }
    if (check != -3184520110874351802L) return 2;
    int d[40];
    for (int i = 0; i < 40; i++) d[i] = i * i - 50;
    if (down(d, 9, 4) != 17055) return 3;
    if (last_index(d, 13, 22 * 22 - 50) != 7) return 4;
    if (last_index(d, 13, 12345) != 13) return 5;
    short w[64];
    for (int i = 0; i < 64; i++) w[i] = (short)(i * 3 - 90);
    if (window(w, 32, 9) != 2508) return 6;
    return 0;
}
