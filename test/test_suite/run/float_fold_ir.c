// #kind: run
// #exit: 0
/* Compare folded floating point expressions with volatile runtime references
   using their value bits, including conversions and unordered comparisons. */
#include <float.h>
#include <stdint.h>

union F32Bits {
  float value;
  unsigned int bits;
};
union F64Bits {
  double value;
  unsigned long long bits;
};
union LongDoubleBits {
  long double value;
  unsigned char bytes[sizeof(long double)];
};

static int same_f32(float a, float b) {
  union F32Bits x = {.value = a}, y = {.value = b};
  return x.bits == y.bits;
}

static int same_f64(double a, double b) {
  union F64Bits x = {.value = a}, y = {.value = b};
  return x.bits == y.bits;
}

static int same_long_double(long double a, long double b) {
  union LongDoubleBits x = {.value = a}, y = {.value = b};
  /* x86 long double stores 80 value bits in the first ten little-endian bytes.
   */
  for (int i = 0; i < 10; i++)
    if (x.bytes[i] != y.bytes[i])
      return 0;
  return 1;
}

int main(void) {
  int failures = 0;
  /* Each operation has an inexact result, a subnormal result, an overflow
     result, and a signed-zero result. Volatile operands keep the reference
     calculation at runtime while the left-hand local remains foldable. */
  volatile float vf_a = 0.1f, vf_b = 0.2f, vf_c = 0.3f, vf_three = 3.0f;
  volatile float vf_min = 0x1p-149f, vf_norm = 0x1p-126f;
  volatile float vf_max = FLT_MAX, vf_two = 2.0f, vf_half = 0.5f;
  volatile float vf_nzero = -0.0f, vf_pzero = 0.0f;
  volatile float vf_edge_add_lhs = -0.0f, vf_edge_add_rhs = 0.0f;
  volatile float vf_edge_sub_lhs = 1.0f, vf_edge_sub_rhs = 1.0f;
  float f_add_inexact = 0.1f + 0.2f, f_add_sub = 0x1p-149f + 0x1p-149f;
  float f_add_overflow = FLT_MAX + FLT_MAX, f_add_zero = -0.0f + -0.0f;
  float f_sub_inexact = 0.3f - 0.2f, f_sub_sub = 0x1p-148f - 0x1p-149f;
  float f_sub_overflow = FLT_MAX - -FLT_MAX, f_sub_zero = -0.0f - 0.0f;
  float f_mul_inexact = 0.1f * 0.2f, f_mul_sub = 0x1p-126f * 0.5f;
  float f_mul_overflow = FLT_MAX * 2.0f, f_mul_zero = -0.0f * 3.0f;
  float f_div_inexact = 1.0f / 3.0f, f_div_sub = 0x1p-126f / 2.0f;
  float f_div_overflow = FLT_MAX / 0.5f, f_div_zero = -0.0f / 3.0f;
  float f_edge_add_zero = -0.0f + 0.0f, f_edge_sub_zero = 1.0f - 1.0f;
  if (!same_f32(f_add_inexact, vf_a + vf_b) ||
      !same_f32(f_add_sub, vf_min + vf_min) ||
      !same_f32(f_add_overflow, vf_max + vf_max) ||
      !same_f32(f_add_zero, vf_nzero + vf_nzero))
    failures |= 1;
  if (!same_f32(f_sub_inexact, vf_c - vf_b) ||
      !same_f32(f_sub_sub, 2.0f * vf_min - vf_min) ||
      !same_f32(f_sub_overflow, vf_max - -vf_max) ||
      !same_f32(f_sub_zero, vf_nzero - vf_pzero))
    failures |= 2;
  if (!same_f32(f_mul_inexact, vf_a * vf_b) ||
      !same_f32(f_mul_sub, vf_norm * vf_half) ||
      !same_f32(f_mul_overflow, vf_max * vf_two) ||
      !same_f32(f_mul_zero, vf_nzero * 3.0f))
    failures |= 4;
  if (!same_f32(f_div_inexact, 1.0f / vf_three) ||
      !same_f32(f_div_sub, vf_norm / vf_two) ||
      !same_f32(f_div_overflow, vf_max / vf_half) ||
      !same_f32(f_div_zero, vf_nzero / 3.0f))
    failures |= 8;
  if (!same_f32(f_edge_add_zero, vf_edge_add_lhs + vf_edge_add_rhs) ||
      !same_f32(f_edge_sub_zero, vf_edge_sub_lhs - vf_edge_sub_rhs))
    failures |= 2097152;

  volatile double vd_a = 0.1, vd_b = 0.2, vd_c = 0.3, vd_three = 3.0;
  volatile double vd_min = 0x1p-1074, vd_norm = 0x1p-1022;
  volatile double vd_max = DBL_MAX, vd_two = 2.0, vd_half = 0.5;
  volatile double vd_nzero = -0.0, vd_pzero = 0.0;
  volatile double vd_edge_add_lhs = -0.0, vd_edge_add_rhs = 0.0;
  volatile double vd_edge_sub_lhs = 1.0, vd_edge_sub_rhs = 1.0;
  double d_add_inexact = 0.1 + 0.2, d_add_sub = 0x1p-1074 + 0x1p-1074;
  double d_add_overflow = DBL_MAX + DBL_MAX, d_add_zero = -0.0 + -0.0;
  double d_sub_inexact = 0.3 - 0.2, d_sub_sub = 0x1p-1073 - 0x1p-1074;
  double d_sub_overflow = DBL_MAX - -DBL_MAX, d_sub_zero = -0.0 - 0.0;
  double d_mul_inexact = 0.1 * 0.2, d_mul_sub = 0x1p-1022 * 0.5;
  double d_mul_overflow = DBL_MAX * 2.0, d_mul_zero = -0.0 * 3.0;
  double d_div_inexact = 1.0 / 3.0, d_div_sub = 0x1p-1022 / 2.0;
  double d_div_overflow = DBL_MAX / 0.5, d_div_zero = -0.0 / 3.0;
  double d_edge_add_zero = -0.0 + 0.0, d_edge_sub_zero = 1.0 - 1.0;
  if (!same_f64(d_add_inexact, vd_a + vd_b) ||
      !same_f64(d_add_sub, vd_min + vd_min) ||
      !same_f64(d_add_overflow, vd_max + vd_max) ||
      !same_f64(d_add_zero, vd_nzero + vd_nzero))
    failures |= 16;
  if (!same_f64(d_sub_inexact, vd_c - vd_b) ||
      !same_f64(d_sub_sub, 2.0 * vd_min - vd_min) ||
      !same_f64(d_sub_overflow, vd_max - -vd_max) ||
      !same_f64(d_sub_zero, vd_nzero - vd_pzero))
    failures |= 32;
  if (!same_f64(d_mul_inexact, vd_a * vd_b) ||
      !same_f64(d_mul_sub, vd_norm * vd_half) ||
      !same_f64(d_mul_overflow, vd_max * vd_two) ||
      !same_f64(d_mul_zero, vd_nzero * 3.0))
    failures |= 64;
  if (!same_f64(d_div_inexact, 1.0 / vd_three) ||
      !same_f64(d_div_sub, vd_norm / vd_two) ||
      !same_f64(d_div_overflow, vd_max / vd_half) ||
      !same_f64(d_div_zero, vd_nzero / 3.0))
    failures |= 128;
  if (!same_f64(d_edge_add_zero, vd_edge_add_lhs + vd_edge_add_rhs) ||
      !same_f64(d_edge_sub_zero, vd_edge_sub_lhs - vd_edge_sub_rhs))
    failures |= 4194304;

  volatile long double vl_a = 0.1L, vl_b = 0.2L, vl_c = 0.3L, vl_three = 3.0L;
  volatile long double vl_min = 0x1p-16445L, vl_norm = 0x1p-16382L;
  volatile long double vl_max = LDBL_MAX, vl_two = 2.0L, vl_half = 0.5L;
  volatile long double vl_nzero = -0.0L, vl_pzero = 0.0L;
  volatile long double vl_edge_add_lhs = -0.0L, vl_edge_add_rhs = 0.0L;
  volatile long double vl_edge_sub_lhs = 1.0L, vl_edge_sub_rhs = 1.0L;
  long double l_add_inexact = 0.1L + 0.2L,
              l_add_sub = 0x1p-16445L + 0x1p-16445L;
  long double l_add_overflow = LDBL_MAX + LDBL_MAX, l_add_zero = -0.0L + -0.0L;
  long double l_sub_inexact = 0.3L - 0.2L,
              l_sub_sub = 0x1p-16444L - 0x1p-16445L;
  long double l_sub_overflow = LDBL_MAX - -LDBL_MAX, l_sub_zero = -0.0L - 0.0L;
  long double l_mul_inexact = 0.1L * 0.2L, l_mul_sub = 0x1p-16382L * 0.5L;
  long double l_mul_overflow = LDBL_MAX * 2.0L, l_mul_zero = -0.0L * 3.0L;
  long double l_div_inexact = 1.0L / 3.0L, l_div_sub = 0x1p-16382L / 2.0L;
  long double l_div_overflow = LDBL_MAX / 0.5L, l_div_zero = -0.0L / 3.0L;
  long double l_edge_add_zero = -0.0L + 0.0L, l_edge_sub_zero = 1.0L - 1.0L;
  if (!same_long_double(l_add_inexact, vl_a + vl_b) ||
      !same_long_double(l_add_sub, vl_min + vl_min) ||
      !same_long_double(l_add_overflow, vl_max + vl_max) ||
      !same_long_double(l_add_zero, vl_nzero + vl_nzero))
    failures |= 256;
  if (!same_long_double(l_sub_inexact, vl_c - vl_b) ||
      !same_long_double(l_sub_sub, 2.0L * vl_min - vl_min) ||
      !same_long_double(l_sub_overflow, vl_max - -vl_max) ||
      !same_long_double(l_sub_zero, vl_nzero - vl_pzero))
    failures |= 512;
  if (!same_long_double(l_mul_inexact, vl_a * vl_b) ||
      !same_long_double(l_mul_sub, vl_norm * vl_half) ||
      !same_long_double(l_mul_overflow, vl_max * vl_two) ||
      !same_long_double(l_mul_zero, vl_nzero * 3.0L))
    failures |= 1024;
  if (!same_long_double(l_div_inexact, 1.0L / vl_three) ||
      !same_long_double(l_div_sub, vl_norm / vl_two) ||
      !same_long_double(l_div_overflow, vl_max / vl_half) ||
      !same_long_double(l_div_zero, vl_nzero / 3.0L))
    failures |= 2048;
  if (!same_long_double(l_edge_add_zero, vl_edge_add_lhs + vl_edge_add_rhs) ||
      !same_long_double(l_edge_sub_zero, vl_edge_sub_lhs - vl_edge_sub_rhs))
    failures |= 8388608;

  volatile int vi = 16777217;
  volatile double vd_convert = -123.875;
  volatile float vf_convert = 16777217.0f;
  volatile unsigned long long vu53 = 9007199254740993ULL;
  volatile unsigned long long vu64 = UINT64_MAX;
  volatile long double vl_fptosi_negative = -0.9L;
  volatile long double vl_fptosi_boundary = 2147483647.5L;
  float f_int_edge = (float)16777217;
  float f_runtime_int_edge = (float)vi;
  int fptosi_edge = (int)-123.875;
  int fptosi_runtime_edge = (int)vd_convert;
  double fpext_edge = (double)16777217.0f;
  double fpext_runtime_edge = (double)vf_convert;
  double d_int_53_edge = (double)9007199254740993ULL;
  double d_runtime_int_53_edge = (double)vu53;
  double d_uint64_edge = (double)UINT64_MAX;
  double d_runtime_uint64_edge = (double)vu64;
  int fptosi_negative_edge = (int)-0.9L;
  int fptosi_runtime_negative_edge = (int)vl_fptosi_negative;
  int fptosi_boundary_edge = (int)2147483647.5L;
  int fptosi_runtime_boundary_edge = (int)vl_fptosi_boundary;
  if (!same_f32(f_int_edge, f_runtime_int_edge))
    failures |= 4096;
  if (fptosi_edge != fptosi_runtime_edge)
    failures |= 8192;
  if (!same_f64(fpext_edge, fpext_runtime_edge))
    failures |= 16384;
  if (!same_f64(d_int_53_edge, d_runtime_int_53_edge))
    failures |= 32768;
  if (!same_f64(d_uint64_edge, d_runtime_uint64_edge))
    failures |= 65536;
  if (fptosi_negative_edge != fptosi_runtime_negative_edge)
    failures |= 131072;
  if (fptosi_boundary_edge != fptosi_runtime_boundary_edge)
    failures |= 262144;

  volatile float vf_nan = 0.0f / 0.0f;
  volatile double vd_nan = 0.0 / 0.0;
  float f_nan = 0.0f / 0.0f;
  double d_nan = 0.0 / 0.0;
  if ((f_nan == f_nan) != (vf_nan == vf_nan) ||
      (f_nan != f_nan) != (vf_nan != vf_nan) ||
      (f_nan < 1.0f) != (vf_nan < 1.0f) ||
      (f_nan <= 1.0f) != (vf_nan <= 1.0f) ||
      (f_nan > 1.0f) != (vf_nan > 1.0f) || (f_nan >= 1.0f) != (vf_nan >= 1.0f))
    failures |= 524288;
  if ((d_nan == d_nan) != (vd_nan == vd_nan) ||
      (d_nan != d_nan) != (vd_nan != vd_nan) ||
      (d_nan < 1.0) != (vd_nan < 1.0) || (d_nan <= 1.0) != (vd_nan <= 1.0) ||
      (d_nan > 1.0) != (vd_nan > 1.0) || (d_nan >= 1.0) != (vd_nan >= 1.0))
    failures |= 1048576;
  return failures;
}
