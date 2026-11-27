// #kind: run
// #exit: 0
#include <limits.h>

/* Small integer types promote to int before division. */
#define CHECK_SIGNED_DIV(type, runtime_type, min_value, max_value, constant) do { \
	type values[] = { \
		(type)(min_value), (type)((min_value) + 1), \
		(type)((min_value) / 2), (type)-33, \
		(type)-17, (type)-9, (type)-8, (type)-7, (type)-3, \
		(type)-2, (type)-1, (type)0, (type)1, (type)2, (type)3, \
		(type)7, (type)8, (type)9, (type)17, (type)33, \
		(type)((max_value) / 2), (type)((max_value) - 1), (type)(max_value) \
	}; \
	volatile runtime_type runtime_divisor = (constant); \
	for (unsigned long i = 0; i < sizeof(values) / sizeof(values[0]); ++i) { \
		/* The only signed division overflow is minimum / -1. */ \
		if (!((constant) == -1 && values[i] == (type)(min_value))) { \
			if (values[i] / (constant) != values[i] / runtime_divisor || \
			    values[i] % (constant) != values[i] % runtime_divisor) return 1; \
		} \
	} \
	for (int stride_value = -100; stride_value <= 100; stride_value += 7) { \
		type dividend = (type)stride_value; \
		if (!((constant) == -1 && dividend == (type)(min_value))) { \
			if (dividend / (constant) != dividend / runtime_divisor || \
			    dividend % (constant) != dividend % runtime_divisor) return 1; \
		} \
	} \
} while (0)

#define CHECK_UNSIGNED_DIV(type, runtime_type, max_value, constant) do { \
	type values[] = { \
		(type)0, (type)1, (type)2, (type)7, (type)8, (type)9, \
		(type)10, (type)17, (type)33, \
		(type)((max_value) / 2), (type)((max_value) - 1), (type)(max_value) \
	}; \
	volatile runtime_type runtime_divisor = (constant); \
	for (unsigned long i = 0; i < sizeof(values) / sizeof(values[0]); ++i) { \
		if (values[i] / (constant) != values[i] / runtime_divisor || \
		    values[i] % (constant) != values[i] % runtime_divisor) return 1; \
	} \
	for (unsigned int stride_value = 0; stride_value <= 100; stride_value += 7) { \
		type dividend = (type)stride_value; \
		if (dividend / (constant) != dividend / runtime_divisor || \
		    dividend % (constant) != dividend % runtime_divisor) return 1; \
	} \
} while (0)

#define CHECK_SIGNED_WIDTH(type, runtime_type, min_value, max_value) do { \
	CHECK_SIGNED_DIV(type, runtime_type, min_value, max_value, 1); \
	CHECK_SIGNED_DIV(type, runtime_type, min_value, max_value, -1); \
	CHECK_SIGNED_DIV(type, runtime_type, min_value, max_value, 2); \
	CHECK_SIGNED_DIV(type, runtime_type, min_value, max_value, -2); \
	CHECK_SIGNED_DIV(type, runtime_type, min_value, max_value, 3); \
	CHECK_SIGNED_DIV(type, runtime_type, min_value, max_value, -3); \
	CHECK_SIGNED_DIV(type, runtime_type, min_value, max_value, 6); \
	CHECK_SIGNED_DIV(type, runtime_type, min_value, max_value, -14); \
	CHECK_SIGNED_DIV(type, runtime_type, min_value, max_value, 5); \
	CHECK_SIGNED_DIV(type, runtime_type, min_value, max_value, -5); \
	CHECK_SIGNED_DIV(type, runtime_type, min_value, max_value, 9); \
	CHECK_SIGNED_DIV(type, runtime_type, min_value, max_value, -9); \
	CHECK_SIGNED_DIV(type, runtime_type, min_value, max_value, 7); \
	CHECK_SIGNED_DIV(type, runtime_type, min_value, max_value, -7); \
	CHECK_SIGNED_DIV(type, runtime_type, min_value, max_value, 8); \
	CHECK_SIGNED_DIV(type, runtime_type, min_value, max_value, -8); \
	CHECK_SIGNED_DIV(type, runtime_type, min_value, max_value, 10); \
	CHECK_SIGNED_DIV(type, runtime_type, min_value, max_value, -10); \
	CHECK_SIGNED_DIV(type, runtime_type, min_value, max_value, 641); \
	CHECK_SIGNED_DIV(type, runtime_type, min_value, max_value, -641); \
	CHECK_SIGNED_DIV(type, runtime_type, min_value, max_value, max_value); \
	CHECK_SIGNED_DIV(type, runtime_type, min_value, max_value, min_value); \
} while (0)

#define CHECK_UNSIGNED_WIDTH(type, runtime_type, max_value) do { \
	CHECK_UNSIGNED_DIV(type, runtime_type, max_value, 1); \
	CHECK_UNSIGNED_DIV(type, runtime_type, max_value, 2); \
	CHECK_UNSIGNED_DIV(type, runtime_type, max_value, 3); \
	CHECK_UNSIGNED_DIV(type, runtime_type, max_value, 6); \
	CHECK_UNSIGNED_DIV(type, runtime_type, max_value, 14); \
	CHECK_UNSIGNED_DIV(type, runtime_type, max_value, 28); \
	CHECK_UNSIGNED_DIV(type, runtime_type, max_value, 5); \
	CHECK_UNSIGNED_DIV(type, runtime_type, max_value, 7); \
	CHECK_UNSIGNED_DIV(type, runtime_type, max_value, 8); \
	CHECK_UNSIGNED_DIV(type, runtime_type, max_value, 9); \
	CHECK_UNSIGNED_DIV(type, runtime_type, max_value, 10); \
	CHECK_UNSIGNED_DIV(type, runtime_type, max_value, 641); \
	CHECK_UNSIGNED_DIV(type, runtime_type, max_value, (max_value) / 2 + 1); \
	CHECK_UNSIGNED_DIV(type, runtime_type, max_value, (max_value) / 2 + 2); \
	CHECK_UNSIGNED_DIV(type, runtime_type, max_value, (max_value) - 1); \
	CHECK_UNSIGNED_DIV(type, runtime_type, max_value, max_value); \
} while (0)

int main(void) {
	CHECK_SIGNED_WIDTH(signed char, int, SCHAR_MIN, SCHAR_MAX);
	CHECK_UNSIGNED_WIDTH(unsigned char, int, UCHAR_MAX);
	CHECK_SIGNED_WIDTH(short, int, SHRT_MIN, SHRT_MAX);
	CHECK_UNSIGNED_WIDTH(unsigned short, int, USHRT_MAX);
	CHECK_SIGNED_WIDTH(int, int, INT_MIN, INT_MAX);
	CHECK_UNSIGNED_WIDTH(unsigned int, unsigned int, UINT_MAX);
	CHECK_UNSIGNED_DIV(unsigned int, unsigned int, UINT_MAX, 0xC0000001U);
	CHECK_SIGNED_WIDTH(long, long, LONG_MIN, LONG_MAX);
	CHECK_UNSIGNED_WIDTH(unsigned long, unsigned long, ULONG_MAX);
	CHECK_SIGNED_WIDTH(long long, long long, LLONG_MIN, LLONG_MAX);
	CHECK_UNSIGNED_WIDTH(unsigned long long, unsigned long long, ULLONG_MAX);
	CHECK_UNSIGNED_DIV(unsigned long long, unsigned long long, ULLONG_MAX,
		0x8000000000000001ULL);
	CHECK_UNSIGNED_DIV(unsigned long long, unsigned long long, ULLONG_MAX,
		0xFFFFFFFFFFFFFFFEULL);
	return 0;
}
