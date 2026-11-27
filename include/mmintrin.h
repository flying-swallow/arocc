/* aro: MMX intrinsics (<mmintrin.h>), written with the GNU vector extension.
   aro lowers vector operations element-wise; there is no MMX register use. */
#ifndef __ARO_MMINTRIN_H
#define __ARO_MMINTRIN_H

typedef int __m64 __attribute__((__vector_size__(8), __may_alias__));
typedef int __m64_u __attribute__((__vector_size__(8), __may_alias__, __aligned__(1)));
typedef int __v2si __attribute__((__vector_size__(8)));
typedef short __v4hi __attribute__((__vector_size__(8)));
typedef char __v8qi __attribute__((__vector_size__(8)));
typedef long long __v1di __attribute__((__vector_size__(8)));

#define __ARO_MM_INLINE static __inline__ __attribute__((__always_inline__, __unused__))

__ARO_MM_INLINE void _mm_empty(void) {}
__ARO_MM_INLINE __m64 _mm_setzero_si64(void) { return (__m64)(__v2si){0, 0}; }
__ARO_MM_INLINE __m64 _mm_cvtsi32_si64(int __i) { return (__m64)(__v2si){__i, 0}; }
__ARO_MM_INLINE int _mm_cvtsi64_si32(__m64 __m) { return ((__v2si)__m)[0]; }
__ARO_MM_INLINE __m64 _mm_cvtsi64_m64(long long __i) { return (__m64)(__v1di){__i}; }
__ARO_MM_INLINE long long _mm_cvtm64_si64(__m64 __m) { return ((__v1di)__m)[0]; }
__ARO_MM_INLINE __m64 _mm_set_pi32(int __i1, int __i0) { return (__m64)(__v2si){__i0, __i1}; }
__ARO_MM_INLINE __m64 _mm_set1_pi32(int __i) { return (__m64)(__v2si){__i, __i}; }
__ARO_MM_INLINE __m64 _mm_add_pi32(__m64 __a, __m64 __b) { return (__m64)((__v2si)__a + (__v2si)__b); }
__ARO_MM_INLINE __m64 _mm_sub_pi32(__m64 __a, __m64 __b) { return (__m64)((__v2si)__a - (__v2si)__b); }
__ARO_MM_INLINE __m64 _mm_add_pi16(__m64 __a, __m64 __b) { return (__m64)((__v4hi)__a + (__v4hi)__b); }
__ARO_MM_INLINE __m64 _mm_add_pi8(__m64 __a, __m64 __b) { return (__m64)((__v8qi)__a + (__v8qi)__b); }
__ARO_MM_INLINE __m64 _mm_and_si64(__m64 __a, __m64 __b) { return (__m64)((__v1di)__a & (__v1di)__b); }
__ARO_MM_INLINE __m64 _mm_or_si64(__m64 __a, __m64 __b) { return (__m64)((__v1di)__a | (__v1di)__b); }
__ARO_MM_INLINE __m64 _mm_xor_si64(__m64 __a, __m64 __b) { return (__m64)((__v1di)__a ^ (__v1di)__b); }

#endif
