/* aro: SSE intrinsics (<xmmintrin.h>), written with the GNU vector extension.
   aro lowers vector operations element-wise, so these are correct but not fast. */
#ifndef __ARO_XMMINTRIN_H
#define __ARO_XMMINTRIN_H

#include <mmintrin.h>

typedef float __m128 __attribute__((__vector_size__(16), __aligned__(16), __may_alias__));
typedef float __m128_u __attribute__((__vector_size__(16), __aligned__(1), __may_alias__));
typedef float __v4sf __attribute__((__vector_size__(16)));
typedef int __v4si __attribute__((__vector_size__(16)));
typedef unsigned int __v4su __attribute__((__vector_size__(16)));

#define __ARO_SSE_INLINE static __inline__ __attribute__((__always_inline__, __unused__))

#define _MM_SHUFFLE(z, y, x, w) (((z) << 6) | ((y) << 4) | ((x) << 2) | (w))
#define _MM_HINT_T0 3
#define _MM_HINT_T1 2
#define _MM_HINT_T2 1
#define _MM_HINT_NTA 0
#define _mm_prefetch(p, hint) ((void)(p), (void)(hint))

/* Set, load, store. */
__ARO_SSE_INLINE __m128 _mm_setzero_ps(void) { return (__m128){0.0f, 0.0f, 0.0f, 0.0f}; }
__ARO_SSE_INLINE __m128 _mm_set_ps(float __z, float __y, float __x, float __w) { return (__m128){__w, __x, __y, __z}; }
__ARO_SSE_INLINE __m128 _mm_setr_ps(float __w, float __x, float __y, float __z) { return (__m128){__w, __x, __y, __z}; }
__ARO_SSE_INLINE __m128 _mm_set1_ps(float __w) { return (__m128){__w, __w, __w, __w}; }
__ARO_SSE_INLINE __m128 _mm_set_ps1(float __w) { return _mm_set1_ps(__w); }
__ARO_SSE_INLINE __m128 _mm_set_ss(float __w) { return (__m128){__w, 0.0f, 0.0f, 0.0f}; }
__ARO_SSE_INLINE __m128 _mm_load_ps(const float *__p) { return *(const __m128 *)__p; }
__ARO_SSE_INLINE __m128 _mm_loadu_ps(const float *__p) { return *(const __m128_u *)__p; }
__ARO_SSE_INLINE __m128 _mm_load_ss(const float *__p) { return (__m128){*__p, 0.0f, 0.0f, 0.0f}; }
__ARO_SSE_INLINE __m128 _mm_load1_ps(const float *__p) { return _mm_set1_ps(*__p); }
__ARO_SSE_INLINE __m128 _mm_load_ps1(const float *__p) { return _mm_set1_ps(*__p); }
__ARO_SSE_INLINE __m128 _mm_loadr_ps(const float *__p) { __m128 __v = _mm_load_ps(__p); return (__m128){__v[3], __v[2], __v[1], __v[0]}; }
__ARO_SSE_INLINE void _mm_store_ps(float *__p, __m128 __a) { *(__m128 *)__p = __a; }
__ARO_SSE_INLINE void _mm_storeu_ps(float *__p, __m128 __a) { *(__m128_u *)__p = __a; }
__ARO_SSE_INLINE void _mm_store_ss(float *__p, __m128 __a) { *__p = __a[0]; }
__ARO_SSE_INLINE void _mm_store1_ps(float *__p, __m128 __a) { _mm_store_ps(__p, _mm_set1_ps(__a[0])); }
__ARO_SSE_INLINE void _mm_store_ps1(float *__p, __m128 __a) { _mm_store1_ps(__p, __a); }
__ARO_SSE_INLINE void _mm_storer_ps(float *__p, __m128 __a) { _mm_store_ps(__p, (__m128){__a[3], __a[2], __a[1], __a[0]}); }
__ARO_SSE_INLINE void _mm_stream_ps(float *__p, __m128 __a) { _mm_store_ps(__p, __a); }
__ARO_SSE_INLINE __m128 _mm_move_ss(__m128 __a, __m128 __b) { __a[0] = __b[0]; return __a; }
__ARO_SSE_INLINE float _mm_cvtss_f32(__m128 __a) { return __a[0]; }

/* Arithmetic. */
__ARO_SSE_INLINE __m128 _mm_add_ps(__m128 __a, __m128 __b) { return (__m128)((__v4sf)__a + (__v4sf)__b); }
__ARO_SSE_INLINE __m128 _mm_sub_ps(__m128 __a, __m128 __b) { return (__m128)((__v4sf)__a - (__v4sf)__b); }
__ARO_SSE_INLINE __m128 _mm_mul_ps(__m128 __a, __m128 __b) { return (__m128)((__v4sf)__a * (__v4sf)__b); }
__ARO_SSE_INLINE __m128 _mm_div_ps(__m128 __a, __m128 __b) { return (__m128)((__v4sf)__a / (__v4sf)__b); }
__ARO_SSE_INLINE __m128 _mm_add_ss(__m128 __a, __m128 __b) { __a[0] += __b[0]; return __a; }
__ARO_SSE_INLINE __m128 _mm_sub_ss(__m128 __a, __m128 __b) { __a[0] -= __b[0]; return __a; }
__ARO_SSE_INLINE __m128 _mm_mul_ss(__m128 __a, __m128 __b) { __a[0] *= __b[0]; return __a; }
__ARO_SSE_INLINE __m128 _mm_div_ss(__m128 __a, __m128 __b) { __a[0] /= __b[0]; return __a; }
/* minps/maxps return the second operand when either is NaN or both are zero. */
__ARO_SSE_INLINE float __aro_minf(float __a, float __b) { return __a < __b ? __a : __b; }
__ARO_SSE_INLINE float __aro_maxf(float __a, float __b) { return __a > __b ? __a : __b; }
__ARO_SSE_INLINE __m128 _mm_min_ps(__m128 __a, __m128 __b) { for (int __i = 0; __i < 4; __i++) __a[__i] = __aro_minf(__a[__i], __b[__i]); return __a; }
__ARO_SSE_INLINE __m128 _mm_max_ps(__m128 __a, __m128 __b) { for (int __i = 0; __i < 4; __i++) __a[__i] = __aro_maxf(__a[__i], __b[__i]); return __a; }
__ARO_SSE_INLINE __m128 _mm_min_ss(__m128 __a, __m128 __b) { __a[0] = __aro_minf(__a[0], __b[0]); return __a; }
__ARO_SSE_INLINE __m128 _mm_max_ss(__m128 __a, __m128 __b) { __a[0] = __aro_maxf(__a[0], __b[0]); return __a; }
__ARO_SSE_INLINE float __aro_sqrtf(float __x) { float __r; __asm__("sqrtss %1, %0" : "=x"(__r) : "x"(__x)); return __r; }
__ARO_SSE_INLINE __m128 _mm_sqrt_ps(__m128 __a) { for (int __i = 0; __i < 4; __i++) __a[__i] = __aro_sqrtf(__a[__i]); return __a; }
__ARO_SSE_INLINE __m128 _mm_sqrt_ss(__m128 __a) { __a[0] = __aro_sqrtf(__a[0]); return __a; }
__ARO_SSE_INLINE __m128 _mm_rcp_ps(__m128 __a) { return (__m128)(1.0f / (__v4sf)__a); }
__ARO_SSE_INLINE __m128 _mm_rsqrt_ps(__m128 __a) { return (__m128)(1.0f / (__v4sf)_mm_sqrt_ps(__a)); }

/* Bitwise. */
__ARO_SSE_INLINE __m128 _mm_and_ps(__m128 __a, __m128 __b) { return (__m128)((__v4su)__a & (__v4su)__b); }
__ARO_SSE_INLINE __m128 _mm_andnot_ps(__m128 __a, __m128 __b) { return (__m128)(~(__v4su)__a & (__v4su)__b); }
__ARO_SSE_INLINE __m128 _mm_or_ps(__m128 __a, __m128 __b) { return (__m128)((__v4su)__a | (__v4su)__b); }
__ARO_SSE_INLINE __m128 _mm_xor_ps(__m128 __a, __m128 __b) { return (__m128)((__v4su)__a ^ (__v4su)__b); }

/* Comparisons: all-ones lanes where true. */
__ARO_SSE_INLINE __m128 _mm_cmpeq_ps(__m128 __a, __m128 __b) { return (__m128)((__v4sf)__a == (__v4sf)__b); }
__ARO_SSE_INLINE __m128 _mm_cmplt_ps(__m128 __a, __m128 __b) { return (__m128)((__v4sf)__a < (__v4sf)__b); }
__ARO_SSE_INLINE __m128 _mm_cmple_ps(__m128 __a, __m128 __b) { return (__m128)((__v4sf)__a <= (__v4sf)__b); }
__ARO_SSE_INLINE __m128 _mm_cmpgt_ps(__m128 __a, __m128 __b) { return (__m128)((__v4sf)__a > (__v4sf)__b); }
__ARO_SSE_INLINE __m128 _mm_cmpge_ps(__m128 __a, __m128 __b) { return (__m128)((__v4sf)__a >= (__v4sf)__b); }
__ARO_SSE_INLINE __m128 _mm_cmpneq_ps(__m128 __a, __m128 __b) { return (__m128)((__v4sf)__a != (__v4sf)__b); }
__ARO_SSE_INLINE __m128 _mm_cmpord_ps(__m128 __a, __m128 __b) { return (__m128)(((__v4sf)__a == (__v4sf)__a) & ((__v4sf)__b == (__v4sf)__b)); }
__ARO_SSE_INLINE __m128 _mm_cmpunord_ps(__m128 __a, __m128 __b) { return (__m128)(((__v4sf)__a != (__v4sf)__a) | ((__v4sf)__b != (__v4sf)__b)); }
__ARO_SSE_INLINE int _mm_comieq_ss(__m128 __a, __m128 __b) { return __a[0] == __b[0]; }
__ARO_SSE_INLINE int _mm_comilt_ss(__m128 __a, __m128 __b) { return __a[0] < __b[0]; }
__ARO_SSE_INLINE int _mm_comile_ss(__m128 __a, __m128 __b) { return __a[0] <= __b[0]; }
__ARO_SSE_INLINE int _mm_comigt_ss(__m128 __a, __m128 __b) { return __a[0] > __b[0]; }
__ARO_SSE_INLINE int _mm_comige_ss(__m128 __a, __m128 __b) { return __a[0] >= __b[0]; }
__ARO_SSE_INLINE int _mm_comineq_ss(__m128 __a, __m128 __b) { return __a[0] != __b[0]; }
__ARO_SSE_INLINE int _mm_movemask_ps(__m128 __a)
{
	__v4si __v = (__v4si)__a;
	return (__v[0] < 0) | (__v[1] < 0) << 1 | (__v[2] < 0) << 2 | (__v[3] < 0) << 3;
}

/* Shuffles. */
#define _mm_shuffle_ps(a, b, imm) \
	((__m128)__builtin_shufflevector((__v4sf)(__m128)(a), (__v4sf)(__m128)(b), \
		(imm) & 3, ((imm) >> 2) & 3, 4 + (((imm) >> 4) & 3), 4 + (((imm) >> 6) & 3)))
__ARO_SSE_INLINE __m128 _mm_unpacklo_ps(__m128 __a, __m128 __b) { return (__m128)__builtin_shufflevector((__v4sf)__a, (__v4sf)__b, 0, 4, 1, 5); }
__ARO_SSE_INLINE __m128 _mm_unpackhi_ps(__m128 __a, __m128 __b) { return (__m128)__builtin_shufflevector((__v4sf)__a, (__v4sf)__b, 2, 6, 3, 7); }
__ARO_SSE_INLINE __m128 _mm_movehl_ps(__m128 __a, __m128 __b) { return (__m128)__builtin_shufflevector((__v4sf)__a, (__v4sf)__b, 6, 7, 2, 3); }
__ARO_SSE_INLINE __m128 _mm_movelh_ps(__m128 __a, __m128 __b) { return (__m128)__builtin_shufflevector((__v4sf)__a, (__v4sf)__b, 0, 1, 4, 5); }

/* Conversions. */
__ARO_SSE_INLINE __m128 _mm_cvtsi32_ss(__m128 __a, int __b) { __a[0] = (float)__b; return __a; }
__ARO_SSE_INLINE __m128 _mm_cvt_si2ss(__m128 __a, int __b) { return _mm_cvtsi32_ss(__a, __b); }
__ARO_SSE_INLINE __m128 _mm_cvtsi64_ss(__m128 __a, long long __b) { __a[0] = (float)__b; return __a; }
__ARO_SSE_INLINE int _mm_cvttss_si32(__m128 __a) { return (int)__a[0]; }
__ARO_SSE_INLINE int _mm_cvtt_ss2si(__m128 __a) { return (int)__a[0]; }
__ARO_SSE_INLINE long long _mm_cvttss_si64(__m128 __a) { return (long long)__a[0]; }
/* cvtss2si rounds by the MXCSR mode. */
__ARO_SSE_INLINE int _mm_cvtss_si32(__m128 __a) { int __r; float __x = __a[0]; __asm__("cvtss2si %1, %0" : "=r"(__r) : "x"(__x)); return __r; }
__ARO_SSE_INLINE int _mm_cvt_ss2si(__m128 __a) { return _mm_cvtss_si32(__a); }
__ARO_SSE_INLINE long long _mm_cvtss_si64(__m128 __a) { long long __r; float __x = __a[0]; __asm__("cvtss2si %1, %0" : "=r"(__r) : "x"(__x)); return __r; }

/* Control. */
__ARO_SSE_INLINE void _mm_sfence(void) { __asm__ __volatile__("sfence" ::: "memory"); }
__ARO_SSE_INLINE unsigned int _mm_getcsr(void) { unsigned int __r; __asm__ __volatile__("stmxcsr %0" : "=m"(__r)); return __r; }
__ARO_SSE_INLINE void _mm_setcsr(unsigned int __v) { __asm__ __volatile__("ldmxcsr %0" : : "m"(__v)); }

#include <mm_malloc.h>

#endif
