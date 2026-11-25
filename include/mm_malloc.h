/* aro: <mm_malloc.h>: aligned allocation for SIMD data. */
#ifndef __ARO_MM_MALLOC_H
#define __ARO_MM_MALLOC_H
#include <stddef.h>
extern int posix_memalign(void **__memptr, size_t __alignment, size_t __size);
extern void free(void *__ptr);
static __inline__ __attribute__((__unused__)) void *_mm_malloc(size_t __size, size_t __align)
{
	void *__p;
	if (__align < sizeof(void *)) __align = sizeof(void *);
	if (posix_memalign(&__p, __align, __size) != 0) return (void *)0;
	return __p;
}
static __inline__ __attribute__((__unused__)) void _mm_free(void *__p) { free(__p); }
#endif
