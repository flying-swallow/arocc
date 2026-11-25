// #kind: run
// #exit: 0
// `loop_vectorize` (SSE2): contiguous maps and integer sum reductions run 4
// (32-bit lanes) or 2 (64-bit lanes) iterations at a time, the original loop
// runs the remainder, and a runtime overlap check sends aliased calls to the
// scalar loop. Every result is checked against a scalar reference that reads
// through `volatile` (never vectorized), for trip counts around the vector width.

#define N 67

__attribute__((noinline)) static int sum_i32(const int *a, int lo, int hi)
{
    int s = 5;
    for (int i = lo; i < hi; i++) s += a[i];
    return s;
}

__attribute__((noinline)) static long sum_i64(const long *a, int n)
{
    long s = 0, t = 1;
    for (int i = 0; i <= n; i++) { s += a[i]; t += a[i] - 3; }
    return s * 3 + t;
}

__attribute__((noinline)) static void map_i32(int *c, const int *a, const int *b, int k, int n)
{
    for (int i = 0; i < n; i++) c[i] = (a[i] * b[i] - k) ^ (a[i] + 9);
}

__attribute__((noinline)) static void map_f32(float *y, const float *x, float k, int n)
{
    for (int i = 0; i < n; i++) y[i] = y[i] * k + x[i] / 4.0f;
}

__attribute__((noinline)) static void map_f64(double *y, const double *x, double k, int n)
{
    for (int i = 0; i < n; i++) y[i] = (x[i] - k) * (x[i] + k);
}

__attribute__((noinline)) static void fill(long *p, long v, int n)
{
    for (int i = 0; i < n; i++) p[i] = v;
}

__attribute__((noinline)) static void in_place(int *a, int n)
{
    for (int i = 0; i < n; i++) a[i] = a[i] * 2 + 1;
}

__attribute__((noinline)) static void shift_copy(int *dst, const int *src, int n)
{
    for (int i = 0; i < n; i++) dst[i] = src[i] + 1;
}

static int a[N + 8], b[N + 8], c[N + 8], r[N + 8];
static long la[N + 8], lp[N + 8];
static float fx[N + 8], fy[N + 8], fr[N + 8];
static double dx[N + 8], dy[N + 8];

// SSE2 shifts by a loop-uniform count, NOT, and integer / float negation.
__attribute__((noinline)) static void map_shift_i32(int *c, const int *a, int k, int n)
{
    for (int i = 0; i < n; i++) c[i] = (int)(((unsigned)a[i] << 3) ^ (unsigned)(a[i] >> k)) + ~a[i];
}

__attribute__((noinline)) static void map_neg_i64(long *d, const long *s, int n)
{
    // i64 lanes: logical shifts only (SSE2 has no 64-bit arithmetic shift).
    for (int i = 0; i < n; i++) d[i] = -(long)((unsigned long)s[i] >> 5) + (long)((unsigned long)s[i] << 2);
}

__attribute__((noinline)) static void map_neg_f64(double *y, const double *x, double k, int n)
{
    for (int i = 0; i < n; i++) y[i] = -x[i] * k;
}

// char / short loops: narrow_truncated_arith drops C's int promotion so they run
// 16 / 8 lanes. `(a + b) >> 1` must not narrow (the shift reads the carry).
__attribute__((noinline)) static void map_s16(short *d, const short *a, const short *b, int n)
{
    for (int i = 0; i < n; i++) d[i] = a[i] + b[i] * 3;
}

__attribute__((noinline)) static void map_u8(unsigned char *d, const unsigned char *a, int n)
{
    for (int i = 0; i < n; i++) d[i] = a[i] ^ 0x5a;
}

__attribute__((noinline)) static void map_s8(signed char *d, const signed char *a, int n)
{
    for (int i = 0; i < n; i++) d[i] = -(a[i] << 2) + ~a[i];
}

__attribute__((noinline)) static void avg_u8(unsigned char *d, const unsigned char *a, const unsigned char *b, int n)
{
    for (int i = 0; i < n; i++) d[i] = (a[i] + b[i]) >> 1;
}

__attribute__((noinline)) static short sum_s16(const short *a, int n)
{
    short s = 7;
    for (int i = 0; i < n; i++) s += a[i];
    return s;
}

__attribute__((noinline)) static unsigned char sum_u8(const unsigned char *a, int n)
{
    unsigned char s = 0;
    for (int i = 0; i < n; i++) s += a[i];
    return s;
}

static short sa[N + 8], sb[N + 8], sd[N + 8];
static unsigned char ua[N + 8], ub[N + 8], ud[N + 8];
static signed char ca[N + 8], cd[N + 8];

int main(void)
{
    for (int i = 0; i < N + 8; i++)
    {
        a[i] = i * 37 - 900;
        b[i] = 2147483 - i * i * 1001;
        la[i] = (long)i * 4000000011L - 7;
        fx[i] = (float)i * 0.25f;
        dx[i] = i * 1.5 - 20.0;
    }
    volatile int *va = a, *vb = b;
    volatile long *vla = la;
    for (int n = 0; n <= N; n++)
    {
        int lo = n % 5 - 2 < 0 ? 0 : n % 5 - 2;
        int ref = 5;
        for (int i = lo; i < n; i++) ref += va[i];
        if (sum_i32(a, lo, n) != ref) return 1;
        long s = 0, t = 1;
        for (int i = 0; i <= n; i++) { s += vla[i]; t += vla[i] - 3; }
        if (sum_i64(la, n) != s * 3 + t) return 2;
        map_i32(c, a, b, n, n);
        volatile int *vc = c;
        for (int i = 0; i < n; i++)
            if (vc[i] != (int)(((unsigned)va[i] * (unsigned)vb[i] - (unsigned)n) ^ (unsigned)(va[i] + 9))) return 3;
        if (n < N && c[n] != 0 && n == 0) return 4;
        for (int i = 0; i < N + 8; i++) { fy[i] = (float)(i % 7); fr[i] = fy[i]; }
        map_f32(fy, fx, 1.5f, n);
        volatile float *vfr = fr, *vfx = fx;
        for (int i = 0; i < n; i++) vfr[i] = vfr[i] * 1.5f + vfx[i] / 4.0f;
        for (int i = 0; i < N + 8; i++) if (fy[i] != fr[i]) return 5;
        map_f64(dy, dx, 3.0, n);
        volatile double *vdx = dx;
        for (int i = 0; i < n; i++) if (dy[i] != (vdx[i] - 3.0) * (vdx[i] + 3.0)) return 6;
        for (int i = 0; i < N + 8; i++) lp[i] = -1;
        fill(lp + 1, (long)n << 33, n);
        if (lp[0] != -1 || lp[n + 1] != -1) return 7;
        for (int i = 1; i <= n; i++) if (lp[i] != (long)n << 33) return 8;
    }
    for (int i = 0; i < N + 8; i++) r[i] = a[i];
    in_place(r, N);
    for (int i = 0; i < N; i++) if (r[i] != a[i] * 2 + 1) return 9;
    if (r[N] != a[N]) return 10;
    // Overlapping calls: the runtime check must pick the scalar loop.
    // r[i+1] = r[i] + 1 run in order chains from r[0]: r[k] = k. A vector copy would read old values.
    for (int i = 0; i < N + 8; i++) r[i] = i * 3;
    shift_copy(r + 1, r, N);
    for (int i = 0; i <= N; i++) if (r[i] != i) return 11;
    for (int i = 0; i < N + 8; i++) r[i] = i * 3;
    shift_copy(r, r + 2, N);  // reads ahead: plain copy semantics
    for (int i = 0; i < N; i++) if (r[i] != (i + 2) * 3 + 1) return 12;
    for (int n = 0; n <= N; n++)
    {
        volatile int *va = a;
        volatile long *vla = la;
        volatile double *vdx = dx;
        map_shift_i32(c, a, n % 13, n);
        for (int i = 0; i < n; i++)
            if (c[i] != (int)(((unsigned)va[i] << 3) ^ (unsigned)(va[i] >> (n % 13))) + ~va[i]) return 20;
        long ld[N + 8];
        map_neg_i64(ld, la, n);
        for (int i = 0; i < n; i++)
            if (ld[i] != -(long)((unsigned long)vla[i] >> 5) + (long)((unsigned long)vla[i] << 2)) return 21;
        double dy[N + 8];
        map_neg_f64(dy, dx, 0.75, n);
        for (int i = 0; i < n; i++) if (dy[i] != -vdx[i] * 0.75) return 22;
    }
    for (int i = 0; i < N + 8; i++)
    {
        sa[i] = (short)(i * 1234 - 30000);
        sb[i] = (short)(17000 - i * 999);
        ua[i] = (unsigned char)(i * 37 + 200);
        ub[i] = (unsigned char)(255 - i * 11);
        ca[i] = (signed char)(i * 29 - 100);
    }
    for (int n = 0; n <= N; n++)
    {
        volatile short *vsa = sa, *vsb = sb;
        volatile unsigned char *vua = ua, *vub = ub;
        volatile signed char *vca = ca;
        map_s16(sd, sa, sb, n);
        for (int i = 0; i < n; i++) if (sd[i] != (short)(vsa[i] + vsb[i] * 3)) return 30;
        map_u8(ud, ua, n);
        for (int i = 0; i < n; i++) if (ud[i] != (unsigned char)(vua[i] ^ 0x5a)) return 31;
        map_s8(cd, ca, n);
        for (int i = 0; i < n; i++) if (cd[i] != (signed char)(-(vca[i] * 4) + ~vca[i])) return 32;
        avg_u8(ud, ua, ub, n);
        for (int i = 0; i < n; i++) if (ud[i] != (unsigned char)((vua[i] + vub[i]) >> 1)) return 33;
        short s = 7;
        for (int i = 0; i < n; i++) s = (short)(s + vsa[i]);
        if (sum_s16(sa, n) != s) return 34;
        unsigned char u = 0;
        for (int i = 0; i < n; i++) u = (unsigned char)(u + vua[i]);
        if (sum_u8(ua, n) != u) return 35;
    }
    return 0;
}
