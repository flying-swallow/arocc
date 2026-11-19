/* Minimal stand-in for <xmmintrin.h> used by the gcc.target/x86_64/abi suite:
   the tests only need the __m64/__m128 types (args.h XMM_T union), not the
   SSE intrinsics. Kept in the harness so aro itself ships no intrinsic headers. */
#ifndef ARO_ABI_XMMINTRIN_SHIM_H
#define ARO_ABI_XMMINTRIN_SHIM_H
typedef int __m64 __attribute__((__vector_size__(8), __may_alias__));
typedef float __m128 __attribute__((__vector_size__(16), __may_alias__));
#endif
