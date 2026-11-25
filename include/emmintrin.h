/* aro: SSE2 intrinsics (<emmintrin.h>), written with the GNU vector extension.
   aro lowers vector operations element-wise, so these are correct but not fast. */
#ifndef __ARO_EMMINTRIN_H
#define __ARO_EMMINTRIN_H

#include <xmmintrin.h>

typedef double __m128d __attribute__((__vector_size__(16), __aligned__(16), __may_alias__));
typedef long long __m128i __attribute__((__vector_size__(16), __aligned__(16), __may_alias__));
typedef double __m128d_u __attribute__((__vector_size__(16), __aligned__(1), __may_alias__));
typedef long long __m128i_u __attribute__((__vector_size__(16), __aligned__(1), __may_alias__));
typedef double __v2df __attribute__((__vector_size__(16)));
typedef long long __v2di __attribute__((__vector_size__(16)));
typedef unsigned long long __v2du __attribute__((__vector_size__(16)));
typedef short __v8hi __attribute__((__vector_size__(16)));
typedef unsigned short __v8hu __attribute__((__vector_size__(16)));
typedef char __v16qi __attribute__((__vector_size__(16)));
typedef signed char __v16qs __attribute__((__vector_size__(16)));
typedef unsigned char __v16qu __attribute__((__vector_size__(16)));

#define __ARO_SSE2_INLINE static __inline__ __attribute__((__always_inline__, __unused__))

/* ---- Casts ---- */
__ARO_SSE2_INLINE __m128 _mm_castpd_ps(__m128d __a) { return (__m128)__a; }
__ARO_SSE2_INLINE __m128i _mm_castpd_si128(__m128d __a) { return (__m128i)__a; }
__ARO_SSE2_INLINE __m128d _mm_castps_pd(__m128 __a) { return (__m128d)__a; }
__ARO_SSE2_INLINE __m128i _mm_castps_si128(__m128 __a) { return (__m128i)__a; }
__ARO_SSE2_INLINE __m128 _mm_castsi128_ps(__m128i __a) { return (__m128)__a; }
__ARO_SSE2_INLINE __m128d _mm_castsi128_pd(__m128i __a) { return (__m128d)__a; }

/* ---- Integer set/load/store ---- */
__ARO_SSE2_INLINE __m128i _mm_setzero_si128(void) { return (__m128i){0, 0}; }
__ARO_SSE2_INLINE __m128i _mm_set_epi64x(long long __q1, long long __q0) { return (__m128i){__q0, __q1}; }
__ARO_SSE2_INLINE __m128i _mm_set_epi64(__m64 __q1, __m64 __q0) { return _mm_set_epi64x(((__v1di)__q1)[0], ((__v1di)__q0)[0]); }
__ARO_SSE2_INLINE __m128i _mm_set_epi32(int __i3, int __i2, int __i1, int __i0) { return (__m128i)(__v4si){__i0, __i1, __i2, __i3}; }
__ARO_SSE2_INLINE __m128i _mm_set_epi16(short __w7, short __w6, short __w5, short __w4, short __w3, short __w2, short __w1, short __w0)
{
	return (__m128i)(__v8hi){__w0, __w1, __w2, __w3, __w4, __w5, __w6, __w7};
}
__ARO_SSE2_INLINE __m128i _mm_set_epi8(char __b15, char __b14, char __b13, char __b12, char __b11, char __b10, char __b9, char __b8,
	char __b7, char __b6, char __b5, char __b4, char __b3, char __b2, char __b1, char __b0)
{
	return (__m128i)(__v16qs){__b0, __b1, __b2, __b3, __b4, __b5, __b6, __b7, __b8, __b9, __b10, __b11, __b12, __b13, __b14, __b15};
}
__ARO_SSE2_INLINE __m128i _mm_set1_epi64x(long long __q) { return _mm_set_epi64x(__q, __q); }
__ARO_SSE2_INLINE __m128i _mm_set1_epi64(__m64 __q) { return _mm_set_epi64(__q, __q); }
__ARO_SSE2_INLINE __m128i _mm_set1_epi32(int __i) { return _mm_set_epi32(__i, __i, __i, __i); }
__ARO_SSE2_INLINE __m128i _mm_set1_epi16(short __w) { return _mm_set_epi16(__w, __w, __w, __w, __w, __w, __w, __w); }
__ARO_SSE2_INLINE __m128i _mm_set1_epi8(char __b) { return _mm_set_epi8(__b, __b, __b, __b, __b, __b, __b, __b, __b, __b, __b, __b, __b, __b, __b, __b); }
__ARO_SSE2_INLINE __m128i _mm_setr_epi64(__m64 __q0, __m64 __q1) { return _mm_set_epi64(__q1, __q0); }
__ARO_SSE2_INLINE __m128i _mm_setr_epi32(int __i0, int __i1, int __i2, int __i3) { return _mm_set_epi32(__i3, __i2, __i1, __i0); }
__ARO_SSE2_INLINE __m128i _mm_setr_epi16(short __w0, short __w1, short __w2, short __w3, short __w4, short __w5, short __w6, short __w7)
{
	return _mm_set_epi16(__w7, __w6, __w5, __w4, __w3, __w2, __w1, __w0);
}
__ARO_SSE2_INLINE __m128i _mm_setr_epi8(char __b0, char __b1, char __b2, char __b3, char __b4, char __b5, char __b6, char __b7,
	char __b8, char __b9, char __b10, char __b11, char __b12, char __b13, char __b14, char __b15)
{
	return _mm_set_epi8(__b15, __b14, __b13, __b12, __b11, __b10, __b9, __b8, __b7, __b6, __b5, __b4, __b3, __b2, __b1, __b0);
}
__ARO_SSE2_INLINE __m128i _mm_load_si128(const __m128i *__p) { return *__p; }
__ARO_SSE2_INLINE __m128i _mm_loadu_si128(const void *__p) { return *(const __m128i_u *)__p; }
__ARO_SSE2_INLINE __m128i _mm_lddqu_si128(const void *__p) { return _mm_loadu_si128(__p); }
__ARO_SSE2_INLINE __m128i _mm_loadl_epi64(const void *__p) { return (__m128i){*(const long long __attribute__((__aligned__(1), __may_alias__)) *)__p, 0}; }
__ARO_SSE2_INLINE __m128i _mm_loadu_si64(const void *__p) { return _mm_loadl_epi64(__p); }
__ARO_SSE2_INLINE __m128i _mm_loadu_si32(const void *__p) { return (__m128i)(__v4si){*(const int __attribute__((__aligned__(1), __may_alias__)) *)__p, 0, 0, 0}; }
__ARO_SSE2_INLINE void _mm_store_si128(__m128i *__p, __m128i __a) { *__p = __a; }
__ARO_SSE2_INLINE void _mm_storeu_si128(void *__p, __m128i __a) { *(__m128i_u *)__p = __a; }
__ARO_SSE2_INLINE void _mm_storel_epi64(void *__p, __m128i __a) { *(long long __attribute__((__aligned__(1), __may_alias__)) *)__p = __a[0]; }
__ARO_SSE2_INLINE void _mm_storeu_si64(void *__p, __m128i __a) { _mm_storel_epi64(__p, __a); }
__ARO_SSE2_INLINE void _mm_storeu_si32(void *__p, __m128i __a) { *(int __attribute__((__aligned__(1), __may_alias__)) *)__p = ((__v4si)__a)[0]; }
__ARO_SSE2_INLINE void _mm_stream_si128(__m128i *__p, __m128i __a) { *__p = __a; }
__ARO_SSE2_INLINE void _mm_stream_si32(int *__p, int __a) { *__p = __a; }
__ARO_SSE2_INLINE void _mm_stream_si64(long long *__p, long long __a) { *__p = __a; }
__ARO_SSE2_INLINE void _mm_maskmoveu_si128(__m128i __d, __m128i __n, char *__p)
{
	for (int __i = 0; __i < 16; __i++) if (((__v16qs)__n)[__i] < 0) __p[__i] = ((__v16qs)__d)[__i];
}
__ARO_SSE2_INLINE __m128i _mm_move_epi64(__m128i __a) { return (__m128i){__a[0], 0}; }

/* ---- Integer conversions ---- */
__ARO_SSE2_INLINE __m128i _mm_cvtsi32_si128(int __a) { return (__m128i)(__v4si){__a, 0, 0, 0}; }
__ARO_SSE2_INLINE __m128i _mm_cvtsi64_si128(long long __a) { return (__m128i){__a, 0}; }
__ARO_SSE2_INLINE __m128i _mm_cvtsi64x_si128(long long __a) { return (__m128i){__a, 0}; }
__ARO_SSE2_INLINE int _mm_cvtsi128_si32(__m128i __a) { return ((__v4si)__a)[0]; }
__ARO_SSE2_INLINE long long _mm_cvtsi128_si64(__m128i __a) { return __a[0]; }
__ARO_SSE2_INLINE long long _mm_cvtsi128_si64x(__m128i __a) { return __a[0]; }

/* ---- Integer arithmetic ---- */
__ARO_SSE2_INLINE __m128i _mm_add_epi8(__m128i __a, __m128i __b) { return (__m128i)((__v16qu)__a + (__v16qu)__b); }
__ARO_SSE2_INLINE __m128i _mm_add_epi16(__m128i __a, __m128i __b) { return (__m128i)((__v8hu)__a + (__v8hu)__b); }
__ARO_SSE2_INLINE __m128i _mm_add_epi32(__m128i __a, __m128i __b) { return (__m128i)((__v4su)__a + (__v4su)__b); }
__ARO_SSE2_INLINE __m128i _mm_add_epi64(__m128i __a, __m128i __b) { return (__m128i)((__v2du)__a + (__v2du)__b); }
__ARO_SSE2_INLINE __m128i _mm_sub_epi8(__m128i __a, __m128i __b) { return (__m128i)((__v16qu)__a - (__v16qu)__b); }
__ARO_SSE2_INLINE __m128i _mm_sub_epi16(__m128i __a, __m128i __b) { return (__m128i)((__v8hu)__a - (__v8hu)__b); }
__ARO_SSE2_INLINE __m128i _mm_sub_epi32(__m128i __a, __m128i __b) { return (__m128i)((__v4su)__a - (__v4su)__b); }
__ARO_SSE2_INLINE __m128i _mm_sub_epi64(__m128i __a, __m128i __b) { return (__m128i)((__v2du)__a - (__v2du)__b); }
__ARO_SSE2_INLINE __m128i _mm_mullo_epi16(__m128i __a, __m128i __b) { return (__m128i)((__v8hu)__a * (__v8hu)__b); }
__ARO_SSE2_INLINE __m128i _mm_mulhi_epi16(__m128i __a, __m128i __b)
{
	__v8hi __x = (__v8hi)__a, __y = (__v8hi)__b;
	for (int __i = 0; __i < 8; __i++) __x[__i] = (short)(((int)__x[__i] * __y[__i]) >> 16);
	return (__m128i)__x;
}
__ARO_SSE2_INLINE __m128i _mm_mulhi_epu16(__m128i __a, __m128i __b)
{
	__v8hu __x = (__v8hu)__a, __y = (__v8hu)__b;
	for (int __i = 0; __i < 8; __i++) __x[__i] = (unsigned short)(((unsigned)__x[__i] * __y[__i]) >> 16);
	return (__m128i)__x;
}
__ARO_SSE2_INLINE __m128i _mm_mul_epu32(__m128i __a, __m128i __b)
{
	__v4su __x = (__v4su)__a, __y = (__v4su)__b;
	return (__m128i)(__v2du){(unsigned long long)__x[0] * __y[0], (unsigned long long)__x[2] * __y[2]};
}
__ARO_SSE2_INLINE __m128i _mm_madd_epi16(__m128i __a, __m128i __b)
{
	__v8hi __x = (__v8hi)__a, __y = (__v8hi)__b;
	__v4si __r;
	for (int __i = 0; __i < 4; __i++) __r[__i] = __x[2 * __i] * __y[2 * __i] + __x[2 * __i + 1] * __y[2 * __i + 1];
	return (__m128i)__r;
}
__ARO_SSE2_INLINE signed char __aro_sat8(int __v) { return __v > 127 ? 127 : __v < -128 ? -128 : __v; }
__ARO_SSE2_INLINE unsigned char __aro_satu8(int __v) { return __v > 255 ? 255 : __v < 0 ? 0 : __v; }
__ARO_SSE2_INLINE short __aro_sat16(int __v) { return __v > 32767 ? 32767 : __v < -32768 ? -32768 : __v; }
__ARO_SSE2_INLINE unsigned short __aro_satu16(int __v) { return __v > 65535 ? 65535 : __v < 0 ? 0 : __v; }
__ARO_SSE2_INLINE __m128i _mm_adds_epi8(__m128i __a, __m128i __b)
{
	__v16qi __x = (__v16qi)__a, __y = (__v16qi)__b;
	for (int __i = 0; __i < 16; __i++) __x[__i] = __aro_sat8(__x[__i] + __y[__i]);
	return (__m128i)__x;
}
__ARO_SSE2_INLINE __m128i _mm_adds_epu8(__m128i __a, __m128i __b)
{
	__v16qu __x = (__v16qu)__a, __y = (__v16qu)__b;
	for (int __i = 0; __i < 16; __i++) __x[__i] = __aro_satu8(__x[__i] + __y[__i]);
	return (__m128i)__x;
}
__ARO_SSE2_INLINE __m128i _mm_adds_epi16(__m128i __a, __m128i __b)
{
	__v8hi __x = (__v8hi)__a, __y = (__v8hi)__b;
	for (int __i = 0; __i < 8; __i++) __x[__i] = __aro_sat16(__x[__i] + __y[__i]);
	return (__m128i)__x;
}
__ARO_SSE2_INLINE __m128i _mm_adds_epu16(__m128i __a, __m128i __b)
{
	__v8hu __x = (__v8hu)__a, __y = (__v8hu)__b;
	for (int __i = 0; __i < 8; __i++) __x[__i] = __aro_satu16(__x[__i] + __y[__i]);
	return (__m128i)__x;
}
__ARO_SSE2_INLINE __m128i _mm_subs_epi8(__m128i __a, __m128i __b)
{
	__v16qi __x = (__v16qi)__a, __y = (__v16qi)__b;
	for (int __i = 0; __i < 16; __i++) __x[__i] = __aro_sat8(__x[__i] - __y[__i]);
	return (__m128i)__x;
}
__ARO_SSE2_INLINE __m128i _mm_subs_epu8(__m128i __a, __m128i __b)
{
	__v16qu __x = (__v16qu)__a, __y = (__v16qu)__b;
	for (int __i = 0; __i < 16; __i++) __x[__i] = __aro_satu8(__x[__i] - __y[__i]);
	return (__m128i)__x;
}
__ARO_SSE2_INLINE __m128i _mm_subs_epi16(__m128i __a, __m128i __b)
{
	__v8hi __x = (__v8hi)__a, __y = (__v8hi)__b;
	for (int __i = 0; __i < 8; __i++) __x[__i] = __aro_sat16(__x[__i] - __y[__i]);
	return (__m128i)__x;
}
__ARO_SSE2_INLINE __m128i _mm_subs_epu16(__m128i __a, __m128i __b)
{
	__v8hu __x = (__v8hu)__a, __y = (__v8hu)__b;
	for (int __i = 0; __i < 8; __i++) __x[__i] = __aro_satu16(__x[__i] - __y[__i]);
	return (__m128i)__x;
}
__ARO_SSE2_INLINE __m128i _mm_avg_epu8(__m128i __a, __m128i __b)
{
	__v16qu __x = (__v16qu)__a, __y = (__v16qu)__b;
	for (int __i = 0; __i < 16; __i++) __x[__i] = (unsigned char)((__x[__i] + __y[__i] + 1) >> 1);
	return (__m128i)__x;
}
__ARO_SSE2_INLINE __m128i _mm_avg_epu16(__m128i __a, __m128i __b)
{
	__v8hu __x = (__v8hu)__a, __y = (__v8hu)__b;
	for (int __i = 0; __i < 8; __i++) __x[__i] = (unsigned short)((__x[__i] + __y[__i] + 1) >> 1);
	return (__m128i)__x;
}
__ARO_SSE2_INLINE __m128i _mm_sad_epu8(__m128i __a, __m128i __b)
{
	__v16qu __x = (__v16qu)__a, __y = (__v16qu)__b;
	unsigned long long __s0 = 0, __s1 = 0;
	for (int __i = 0; __i < 8; __i++) __s0 += __x[__i] > __y[__i] ? __x[__i] - __y[__i] : __y[__i] - __x[__i];
	for (int __i = 8; __i < 16; __i++) __s1 += __x[__i] > __y[__i] ? __x[__i] - __y[__i] : __y[__i] - __x[__i];
	return (__m128i)(__v2du){__s0, __s1};
}
__ARO_SSE2_INLINE __m128i _mm_max_epu8(__m128i __a, __m128i __b)
{
	__v16qu __x = (__v16qu)__a, __y = (__v16qu)__b;
	for (int __i = 0; __i < 16; __i++) if (__y[__i] > __x[__i]) __x[__i] = __y[__i];
	return (__m128i)__x;
}
__ARO_SSE2_INLINE __m128i _mm_min_epu8(__m128i __a, __m128i __b)
{
	__v16qu __x = (__v16qu)__a, __y = (__v16qu)__b;
	for (int __i = 0; __i < 16; __i++) if (__y[__i] < __x[__i]) __x[__i] = __y[__i];
	return (__m128i)__x;
}
__ARO_SSE2_INLINE __m128i _mm_max_epi16(__m128i __a, __m128i __b)
{
	__v8hi __x = (__v8hi)__a, __y = (__v8hi)__b;
	for (int __i = 0; __i < 8; __i++) if (__y[__i] > __x[__i]) __x[__i] = __y[__i];
	return (__m128i)__x;
}
__ARO_SSE2_INLINE __m128i _mm_min_epi16(__m128i __a, __m128i __b)
{
	__v8hi __x = (__v8hi)__a, __y = (__v8hi)__b;
	for (int __i = 0; __i < 8; __i++) if (__y[__i] < __x[__i]) __x[__i] = __y[__i];
	return (__m128i)__x;
}

/* ---- Integer logic ---- */
__ARO_SSE2_INLINE __m128i _mm_and_si128(__m128i __a, __m128i __b) { return (__m128i)((__v2du)__a & (__v2du)__b); }
__ARO_SSE2_INLINE __m128i _mm_andnot_si128(__m128i __a, __m128i __b) { return (__m128i)(~(__v2du)__a & (__v2du)__b); }
__ARO_SSE2_INLINE __m128i _mm_or_si128(__m128i __a, __m128i __b) { return (__m128i)((__v2du)__a | (__v2du)__b); }
__ARO_SSE2_INLINE __m128i _mm_xor_si128(__m128i __a, __m128i __b) { return (__m128i)((__v2du)__a ^ (__v2du)__b); }

/* ---- Shifts (counts above the lane width give 0, or the sign for sra) ---- */
__ARO_SSE2_INLINE __m128i _mm_slli_epi16(__m128i __a, int __n)
{
	if (__n > 15 || __n < 0) return _mm_setzero_si128();
	return (__m128i)((__v8hu)__a << __n);
}
__ARO_SSE2_INLINE __m128i _mm_slli_epi32(__m128i __a, int __n)
{
	if (__n > 31 || __n < 0) return _mm_setzero_si128();
	return (__m128i)((__v4su)__a << __n);
}
__ARO_SSE2_INLINE __m128i _mm_slli_epi64(__m128i __a, int __n)
{
	if (__n > 63 || __n < 0) return _mm_setzero_si128();
	return (__m128i)((__v2du)__a << __n);
}
__ARO_SSE2_INLINE __m128i _mm_srli_epi16(__m128i __a, int __n)
{
	if (__n > 15 || __n < 0) return _mm_setzero_si128();
	return (__m128i)((__v8hu)__a >> __n);
}
__ARO_SSE2_INLINE __m128i _mm_srli_epi32(__m128i __a, int __n)
{
	if (__n > 31 || __n < 0) return _mm_setzero_si128();
	return (__m128i)((__v4su)__a >> __n);
}
__ARO_SSE2_INLINE __m128i _mm_srli_epi64(__m128i __a, int __n)
{
	if (__n > 63 || __n < 0) return _mm_setzero_si128();
	return (__m128i)((__v2du)__a >> __n);
}
__ARO_SSE2_INLINE __m128i _mm_srai_epi16(__m128i __a, int __n)
{
	if (__n > 15 || __n < 0) __n = 15;
	return (__m128i)((__v8hi)__a >> __n);
}
__ARO_SSE2_INLINE __m128i _mm_srai_epi32(__m128i __a, int __n)
{
	if (__n > 31 || __n < 0) __n = 31;
	return (__m128i)((__v4si)__a >> __n);
}
__ARO_SSE2_INLINE int __aro_shift_count(__m128i __c) { return __c[0] > 255 || __c[0] < 0 ? 255 : (int)__c[0]; }
__ARO_SSE2_INLINE __m128i _mm_sll_epi16(__m128i __a, __m128i __c) { return _mm_slli_epi16(__a, __aro_shift_count(__c)); }
__ARO_SSE2_INLINE __m128i _mm_sll_epi32(__m128i __a, __m128i __c) { return _mm_slli_epi32(__a, __aro_shift_count(__c)); }
__ARO_SSE2_INLINE __m128i _mm_sll_epi64(__m128i __a, __m128i __c) { return _mm_slli_epi64(__a, __aro_shift_count(__c)); }
__ARO_SSE2_INLINE __m128i _mm_srl_epi16(__m128i __a, __m128i __c) { return _mm_srli_epi16(__a, __aro_shift_count(__c)); }
__ARO_SSE2_INLINE __m128i _mm_srl_epi32(__m128i __a, __m128i __c) { return _mm_srli_epi32(__a, __aro_shift_count(__c)); }
__ARO_SSE2_INLINE __m128i _mm_srl_epi64(__m128i __a, __m128i __c) { return _mm_srli_epi64(__a, __aro_shift_count(__c)); }
__ARO_SSE2_INLINE __m128i _mm_sra_epi16(__m128i __a, __m128i __c) { return _mm_srai_epi16(__a, __aro_shift_count(__c)); }
__ARO_SSE2_INLINE __m128i _mm_sra_epi32(__m128i __a, __m128i __c) { return _mm_srai_epi32(__a, __aro_shift_count(__c)); }
/* Whole-register byte shifts (`imm` must be a constant): lane 16 of the
   shuffle is a zero byte. */
#define __ARO_BSR(imm, i) ((imm) + (i) > 15 ? 16 : (imm) + (i))
#define _mm_srli_si128(a, imm) ((__m128i)__builtin_shufflevector((__v16qi)(__m128i)(a), (__v16qi)_mm_setzero_si128(), \
	__ARO_BSR(imm, 0), __ARO_BSR(imm, 1), __ARO_BSR(imm, 2), __ARO_BSR(imm, 3), __ARO_BSR(imm, 4), __ARO_BSR(imm, 5), \
	__ARO_BSR(imm, 6), __ARO_BSR(imm, 7), __ARO_BSR(imm, 8), __ARO_BSR(imm, 9), __ARO_BSR(imm, 10), __ARO_BSR(imm, 11), \
	__ARO_BSR(imm, 12), __ARO_BSR(imm, 13), __ARO_BSR(imm, 14), __ARO_BSR(imm, 15)))
#define __ARO_BSL(imm, i) ((i) < (imm) ? 0 : 16 + (i) - (imm))
#define _mm_slli_si128(a, imm) ((__m128i)__builtin_shufflevector((__v16qi)_mm_setzero_si128(), (__v16qi)(__m128i)(a), \
	__ARO_BSL(imm, 0), __ARO_BSL(imm, 1), __ARO_BSL(imm, 2), __ARO_BSL(imm, 3), __ARO_BSL(imm, 4), __ARO_BSL(imm, 5), \
	__ARO_BSL(imm, 6), __ARO_BSL(imm, 7), __ARO_BSL(imm, 8), __ARO_BSL(imm, 9), __ARO_BSL(imm, 10), __ARO_BSL(imm, 11), \
	__ARO_BSL(imm, 12), __ARO_BSL(imm, 13), __ARO_BSL(imm, 14), __ARO_BSL(imm, 15)))
#define _mm_bsrli_si128(a, imm) _mm_srli_si128(a, imm)
#define _mm_bslli_si128(a, imm) _mm_slli_si128(a, imm)

/* ---- Integer comparisons ---- */
__ARO_SSE2_INLINE __m128i _mm_cmpeq_epi8(__m128i __a, __m128i __b) { return (__m128i)((__v16qs)__a == (__v16qs)__b); }
__ARO_SSE2_INLINE __m128i _mm_cmpeq_epi16(__m128i __a, __m128i __b) { return (__m128i)((__v8hi)__a == (__v8hi)__b); }
__ARO_SSE2_INLINE __m128i _mm_cmpeq_epi32(__m128i __a, __m128i __b) { return (__m128i)((__v4si)__a == (__v4si)__b); }
__ARO_SSE2_INLINE __m128i _mm_cmpgt_epi8(__m128i __a, __m128i __b) { return (__m128i)((__v16qi)__a > (__v16qi)__b); }
__ARO_SSE2_INLINE __m128i _mm_cmpgt_epi16(__m128i __a, __m128i __b) { return (__m128i)((__v8hi)__a > (__v8hi)__b); }
__ARO_SSE2_INLINE __m128i _mm_cmpgt_epi32(__m128i __a, __m128i __b) { return (__m128i)((__v4si)__a > (__v4si)__b); }
__ARO_SSE2_INLINE __m128i _mm_cmplt_epi8(__m128i __a, __m128i __b) { return (__m128i)((__v16qi)__a < (__v16qi)__b); }
__ARO_SSE2_INLINE __m128i _mm_cmplt_epi16(__m128i __a, __m128i __b) { return (__m128i)((__v8hi)__a < (__v8hi)__b); }
__ARO_SSE2_INLINE __m128i _mm_cmplt_epi32(__m128i __a, __m128i __b) { return (__m128i)((__v4si)__a < (__v4si)__b); }
__ARO_SSE2_INLINE int _mm_movemask_epi8(__m128i __a)
{
	__v16qi __v = (__v16qi)__a;
	int __m = 0;
	for (int __i = 0; __i < 16; __i++) __m |= (__v[__i] < 0) << __i;
	return __m;
}

/* ---- Pack / unpack / shuffle / extract ---- */
__ARO_SSE2_INLINE __m128i _mm_packs_epi16(__m128i __a, __m128i __b)
{
	__v8hi __x = (__v8hi)__a, __y = (__v8hi)__b;
	__v16qi __r;
	for (int __i = 0; __i < 8; __i++) { __r[__i] = __aro_sat8(__x[__i]); __r[__i + 8] = __aro_sat8(__y[__i]); }
	return (__m128i)__r;
}
__ARO_SSE2_INLINE __m128i _mm_packs_epi32(__m128i __a, __m128i __b)
{
	__v4si __x = (__v4si)__a, __y = (__v4si)__b;
	__v8hi __r;
	for (int __i = 0; __i < 4; __i++) { __r[__i] = __aro_sat16(__x[__i]); __r[__i + 4] = __aro_sat16(__y[__i]); }
	return (__m128i)__r;
}
__ARO_SSE2_INLINE __m128i _mm_packus_epi16(__m128i __a, __m128i __b)
{
	__v8hi __x = (__v8hi)__a, __y = (__v8hi)__b;
	__v16qu __r;
	for (int __i = 0; __i < 8; __i++) { __r[__i] = __aro_satu8(__x[__i]); __r[__i + 8] = __aro_satu8(__y[__i]); }
	return (__m128i)__r;
}
__ARO_SSE2_INLINE __m128i _mm_unpacklo_epi8(__m128i __a, __m128i __b)
{
	return (__m128i)__builtin_shufflevector((__v16qi)__a, (__v16qi)__b, 0, 16, 1, 17, 2, 18, 3, 19, 4, 20, 5, 21, 6, 22, 7, 23);
}
__ARO_SSE2_INLINE __m128i _mm_unpackhi_epi8(__m128i __a, __m128i __b)
{
	return (__m128i)__builtin_shufflevector((__v16qi)__a, (__v16qi)__b, 8, 24, 9, 25, 10, 26, 11, 27, 12, 28, 13, 29, 14, 30, 15, 31);
}
__ARO_SSE2_INLINE __m128i _mm_unpacklo_epi16(__m128i __a, __m128i __b) { return (__m128i)__builtin_shufflevector((__v8hi)__a, (__v8hi)__b, 0, 8, 1, 9, 2, 10, 3, 11); }
__ARO_SSE2_INLINE __m128i _mm_unpackhi_epi16(__m128i __a, __m128i __b) { return (__m128i)__builtin_shufflevector((__v8hi)__a, (__v8hi)__b, 4, 12, 5, 13, 6, 14, 7, 15); }
__ARO_SSE2_INLINE __m128i _mm_unpacklo_epi32(__m128i __a, __m128i __b) { return (__m128i)__builtin_shufflevector((__v4si)__a, (__v4si)__b, 0, 4, 1, 5); }
__ARO_SSE2_INLINE __m128i _mm_unpackhi_epi32(__m128i __a, __m128i __b) { return (__m128i)__builtin_shufflevector((__v4si)__a, (__v4si)__b, 2, 6, 3, 7); }
__ARO_SSE2_INLINE __m128i _mm_unpacklo_epi64(__m128i __a, __m128i __b) { return (__m128i)__builtin_shufflevector((__v2di)__a, (__v2di)__b, 0, 2); }
__ARO_SSE2_INLINE __m128i _mm_unpackhi_epi64(__m128i __a, __m128i __b) { return (__m128i)__builtin_shufflevector((__v2di)__a, (__v2di)__b, 1, 3); }
#define _mm_shuffle_epi32(a, imm) ((__m128i)__builtin_shufflevector((__v4si)(__m128i)(a), (__v4si)(__m128i)(a), \
	(imm) & 3, ((imm) >> 2) & 3, ((imm) >> 4) & 3, ((imm) >> 6) & 3))
#define _mm_shufflelo_epi16(a, imm) ((__m128i)__builtin_shufflevector((__v8hi)(__m128i)(a), (__v8hi)(__m128i)(a), \
	(imm) & 3, ((imm) >> 2) & 3, ((imm) >> 4) & 3, ((imm) >> 6) & 3, 4, 5, 6, 7))
#define _mm_shufflehi_epi16(a, imm) ((__m128i)__builtin_shufflevector((__v8hi)(__m128i)(a), (__v8hi)(__m128i)(a), \
	0, 1, 2, 3, 4 + ((imm) & 3), 4 + (((imm) >> 2) & 3), 4 + (((imm) >> 4) & 3), 4 + (((imm) >> 6) & 3)))
#define _mm_extract_epi16(a, imm) ((int)(unsigned short)((__v8hi)(__m128i)(a))[(imm) & 7])
__ARO_SSE2_INLINE __m128i __aro_insert_epi16(__m128i __a, int __v, int __i) { __v8hi __x = (__v8hi)__a; __x[__i & 7] = (short)__v; return (__m128i)__x; }
#define _mm_insert_epi16(a, v, imm) __aro_insert_epi16((a), (v), (imm))

/* ---- Double precision ---- */
__ARO_SSE2_INLINE __m128d _mm_setzero_pd(void) { return (__m128d){0.0, 0.0}; }
__ARO_SSE2_INLINE __m128d _mm_set_pd(double __b, double __a) { return (__m128d){__a, __b}; }
__ARO_SSE2_INLINE __m128d _mm_setr_pd(double __a, double __b) { return (__m128d){__a, __b}; }
__ARO_SSE2_INLINE __m128d _mm_set1_pd(double __a) { return (__m128d){__a, __a}; }
__ARO_SSE2_INLINE __m128d _mm_set_pd1(double __a) { return (__m128d){__a, __a}; }
__ARO_SSE2_INLINE __m128d _mm_set_sd(double __a) { return (__m128d){__a, 0.0}; }
__ARO_SSE2_INLINE __m128d _mm_load_pd(const double *__p) { return *(const __m128d *)__p; }
__ARO_SSE2_INLINE __m128d _mm_loadu_pd(const double *__p) { return *(const __m128d_u *)__p; }
__ARO_SSE2_INLINE __m128d _mm_load_sd(const double *__p) { return (__m128d){*__p, 0.0}; }
__ARO_SSE2_INLINE __m128d _mm_load1_pd(const double *__p) { return _mm_set1_pd(*__p); }
__ARO_SSE2_INLINE __m128d _mm_load_pd1(const double *__p) { return _mm_set1_pd(*__p); }
__ARO_SSE2_INLINE __m128d _mm_loadr_pd(const double *__p) { __m128d __v = _mm_load_pd(__p); return (__m128d){__v[1], __v[0]}; }
__ARO_SSE2_INLINE __m128d _mm_loadh_pd(__m128d __a, const double *__p) { __a[1] = *__p; return __a; }
__ARO_SSE2_INLINE __m128d _mm_loadl_pd(__m128d __a, const double *__p) { __a[0] = *__p; return __a; }
__ARO_SSE2_INLINE void _mm_store_pd(double *__p, __m128d __a) { *(__m128d *)__p = __a; }
__ARO_SSE2_INLINE void _mm_storeu_pd(double *__p, __m128d __a) { *(__m128d_u *)__p = __a; }
__ARO_SSE2_INLINE void _mm_store_sd(double *__p, __m128d __a) { *__p = __a[0]; }
__ARO_SSE2_INLINE void _mm_storeh_pd(double *__p, __m128d __a) { *__p = __a[1]; }
__ARO_SSE2_INLINE void _mm_storel_pd(double *__p, __m128d __a) { *__p = __a[0]; }
__ARO_SSE2_INLINE void _mm_store1_pd(double *__p, __m128d __a) { _mm_store_pd(__p, _mm_set1_pd(__a[0])); }
__ARO_SSE2_INLINE void _mm_store_pd1(double *__p, __m128d __a) { _mm_store1_pd(__p, __a); }
__ARO_SSE2_INLINE void _mm_storer_pd(double *__p, __m128d __a) { _mm_store_pd(__p, (__m128d){__a[1], __a[0]}); }
__ARO_SSE2_INLINE void _mm_stream_pd(double *__p, __m128d __a) { _mm_store_pd(__p, __a); }
__ARO_SSE2_INLINE double _mm_cvtsd_f64(__m128d __a) { return __a[0]; }
__ARO_SSE2_INLINE __m128d _mm_move_sd(__m128d __a, __m128d __b) { __a[0] = __b[0]; return __a; }
__ARO_SSE2_INLINE __m128d _mm_add_pd(__m128d __a, __m128d __b) { return (__m128d)((__v2df)__a + (__v2df)__b); }
__ARO_SSE2_INLINE __m128d _mm_sub_pd(__m128d __a, __m128d __b) { return (__m128d)((__v2df)__a - (__v2df)__b); }
__ARO_SSE2_INLINE __m128d _mm_mul_pd(__m128d __a, __m128d __b) { return (__m128d)((__v2df)__a * (__v2df)__b); }
__ARO_SSE2_INLINE __m128d _mm_div_pd(__m128d __a, __m128d __b) { return (__m128d)((__v2df)__a / (__v2df)__b); }
__ARO_SSE2_INLINE __m128d _mm_add_sd(__m128d __a, __m128d __b) { __a[0] += __b[0]; return __a; }
__ARO_SSE2_INLINE __m128d _mm_sub_sd(__m128d __a, __m128d __b) { __a[0] -= __b[0]; return __a; }
__ARO_SSE2_INLINE __m128d _mm_mul_sd(__m128d __a, __m128d __b) { __a[0] *= __b[0]; return __a; }
__ARO_SSE2_INLINE __m128d _mm_div_sd(__m128d __a, __m128d __b) { __a[0] /= __b[0]; return __a; }
__ARO_SSE2_INLINE double __aro_min(double __a, double __b) { return __a < __b ? __a : __b; }
__ARO_SSE2_INLINE double __aro_max(double __a, double __b) { return __a > __b ? __a : __b; }
__ARO_SSE2_INLINE __m128d _mm_min_pd(__m128d __a, __m128d __b) { return (__m128d){__aro_min(__a[0], __b[0]), __aro_min(__a[1], __b[1])}; }
__ARO_SSE2_INLINE __m128d _mm_max_pd(__m128d __a, __m128d __b) { return (__m128d){__aro_max(__a[0], __b[0]), __aro_max(__a[1], __b[1])}; }
__ARO_SSE2_INLINE __m128d _mm_min_sd(__m128d __a, __m128d __b) { __a[0] = __aro_min(__a[0], __b[0]); return __a; }
__ARO_SSE2_INLINE __m128d _mm_max_sd(__m128d __a, __m128d __b) { __a[0] = __aro_max(__a[0], __b[0]); return __a; }
__ARO_SSE2_INLINE double __aro_sqrt(double __x) { double __r; __asm__("sqrtsd %1, %0" : "=x"(__r) : "x"(__x)); return __r; }
__ARO_SSE2_INLINE __m128d _mm_sqrt_pd(__m128d __a) { return (__m128d){__aro_sqrt(__a[0]), __aro_sqrt(__a[1])}; }
__ARO_SSE2_INLINE __m128d _mm_sqrt_sd(__m128d __a, __m128d __b) { __a[0] = __aro_sqrt(__b[0]); return __a; }
__ARO_SSE2_INLINE __m128d _mm_and_pd(__m128d __a, __m128d __b) { return (__m128d)((__v2du)__a & (__v2du)__b); }
__ARO_SSE2_INLINE __m128d _mm_andnot_pd(__m128d __a, __m128d __b) { return (__m128d)(~(__v2du)__a & (__v2du)__b); }
__ARO_SSE2_INLINE __m128d _mm_or_pd(__m128d __a, __m128d __b) { return (__m128d)((__v2du)__a | (__v2du)__b); }
__ARO_SSE2_INLINE __m128d _mm_xor_pd(__m128d __a, __m128d __b) { return (__m128d)((__v2du)__a ^ (__v2du)__b); }
__ARO_SSE2_INLINE __m128d _mm_cmpeq_pd(__m128d __a, __m128d __b) { return (__m128d)((__v2df)__a == (__v2df)__b); }
__ARO_SSE2_INLINE __m128d _mm_cmplt_pd(__m128d __a, __m128d __b) { return (__m128d)((__v2df)__a < (__v2df)__b); }
__ARO_SSE2_INLINE __m128d _mm_cmple_pd(__m128d __a, __m128d __b) { return (__m128d)((__v2df)__a <= (__v2df)__b); }
__ARO_SSE2_INLINE __m128d _mm_cmpgt_pd(__m128d __a, __m128d __b) { return (__m128d)((__v2df)__a > (__v2df)__b); }
__ARO_SSE2_INLINE __m128d _mm_cmpge_pd(__m128d __a, __m128d __b) { return (__m128d)((__v2df)__a >= (__v2df)__b); }
__ARO_SSE2_INLINE __m128d _mm_cmpneq_pd(__m128d __a, __m128d __b) { return (__m128d)((__v2df)__a != (__v2df)__b); }
__ARO_SSE2_INLINE int _mm_comieq_sd(__m128d __a, __m128d __b) { return __a[0] == __b[0]; }
__ARO_SSE2_INLINE int _mm_comilt_sd(__m128d __a, __m128d __b) { return __a[0] < __b[0]; }
__ARO_SSE2_INLINE int _mm_comile_sd(__m128d __a, __m128d __b) { return __a[0] <= __b[0]; }
__ARO_SSE2_INLINE int _mm_comigt_sd(__m128d __a, __m128d __b) { return __a[0] > __b[0]; }
__ARO_SSE2_INLINE int _mm_comige_sd(__m128d __a, __m128d __b) { return __a[0] >= __b[0]; }
__ARO_SSE2_INLINE int _mm_comineq_sd(__m128d __a, __m128d __b) { return __a[0] != __b[0]; }
__ARO_SSE2_INLINE int _mm_movemask_pd(__m128d __a) { __v2di __v = (__v2di)__a; return (__v[0] < 0) | (__v[1] < 0) << 1; }
__ARO_SSE2_INLINE __m128d _mm_unpacklo_pd(__m128d __a, __m128d __b) { return (__m128d)__builtin_shufflevector((__v2df)__a, (__v2df)__b, 0, 2); }
__ARO_SSE2_INLINE __m128d _mm_unpackhi_pd(__m128d __a, __m128d __b) { return (__m128d)__builtin_shufflevector((__v2df)__a, (__v2df)__b, 1, 3); }
#define _mm_shuffle_pd(a, b, imm) ((__m128d)__builtin_shufflevector((__v2df)(__m128d)(a), (__v2df)(__m128d)(b), (imm) & 1, 2 + (((imm) >> 1) & 1)))

/* ---- Float/int conversions ---- */
__ARO_SSE2_INLINE __m128 _mm_cvtepi32_ps(__m128i __a) { return (__m128)__builtin_convertvector((__v4si)__a, __v4sf); }
__ARO_SSE2_INLINE __m128i _mm_cvttps_epi32(__m128 __a) { return (__m128i)__builtin_convertvector((__v4sf)__a, __v4si); }
__ARO_SSE2_INLINE __m128i _mm_cvtps_epi32(__m128 __a)
{
	__v4si __r;
	for (int __i = 0; __i < 4; __i++) __r[__i] = _mm_cvtss_si32(_mm_set_ss(__a[__i]));
	return (__m128i)__r;
}
__ARO_SSE2_INLINE __m128d _mm_cvtepi32_pd(__m128i __a) { __v4si __v = (__v4si)__a; return (__m128d){(double)__v[0], (double)__v[1]}; }
__ARO_SSE2_INLINE int _mm_cvttsd_si32(__m128d __a) { return (int)__a[0]; }
__ARO_SSE2_INLINE long long _mm_cvttsd_si64(__m128d __a) { return (long long)__a[0]; }
__ARO_SSE2_INLINE int _mm_cvtsd_si32(__m128d __a) { int __r; double __x = __a[0]; __asm__("cvtsd2si %1, %0" : "=r"(__r) : "x"(__x)); return __r; }
__ARO_SSE2_INLINE long long _mm_cvtsd_si64(__m128d __a) { long long __r; double __x = __a[0]; __asm__("cvtsd2si %1, %0" : "=r"(__r) : "x"(__x)); return __r; }
__ARO_SSE2_INLINE __m128i _mm_cvttpd_epi32(__m128d __a) { return (__m128i)(__v4si){(int)__a[0], (int)__a[1], 0, 0}; }
__ARO_SSE2_INLINE __m128i _mm_cvtpd_epi32(__m128d __a) { return (__m128i)(__v4si){_mm_cvtsd_si32(__a), _mm_cvtsd_si32(_mm_set_sd(__a[1])), 0, 0}; }
__ARO_SSE2_INLINE __m128 _mm_cvtpd_ps(__m128d __a) { return (__m128){(float)__a[0], (float)__a[1], 0.0f, 0.0f}; }
__ARO_SSE2_INLINE __m128d _mm_cvtps_pd(__m128 __a) { return (__m128d){(double)__a[0], (double)__a[1]}; }
__ARO_SSE2_INLINE __m128d _mm_cvtsi32_sd(__m128d __a, int __b) { __a[0] = (double)__b; return __a; }
__ARO_SSE2_INLINE __m128d _mm_cvtsi64_sd(__m128d __a, long long __b) { __a[0] = (double)__b; return __a; }
__ARO_SSE2_INLINE __m128 _mm_cvtsd_ss(__m128 __a, __m128d __b) { __a[0] = (float)__b[0]; return __a; }
__ARO_SSE2_INLINE __m128d _mm_cvtss_sd(__m128d __a, __m128 __b) { __a[0] = (double)__b[0]; return __a; }

/* ---- Control ---- */
__ARO_SSE2_INLINE void _mm_lfence(void) { __asm__ __volatile__("lfence" ::: "memory"); }
__ARO_SSE2_INLINE void _mm_mfence(void) { __asm__ __volatile__("mfence" ::: "memory"); }
__ARO_SSE2_INLINE void _mm_pause(void) { __asm__ __volatile__("pause"); }
__ARO_SSE2_INLINE void _mm_clflush(const void *__p) { __asm__ __volatile__("clflush %0" : : "m"(*(const char *)__p) : "memory"); }

#endif
