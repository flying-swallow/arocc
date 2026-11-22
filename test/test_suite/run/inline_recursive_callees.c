// #kind: run
// #exit: 0

/* Inlining this helper into recursive and mutually recursive callers must
   leave recursive calls referring to the functions being compiled. */
static inline int add_level(int value)
{
	return value + 3;
}

/* Keep this frame large enough that the inliner should leave it as a call.
   The recursive caller calls it before recursing, so only one such frame is
   live at a time. */
static int large_helper(int value)
{
	volatile unsigned char scratch[4096];
	scratch[0] = (unsigned char)value;
	scratch[sizeof(scratch) - 1] = (unsigned char)(value >> 8);
	return value + scratch[0] + scratch[sizeof(scratch) - 1] -
		(unsigned char)value - (unsigned char)(value >> 8);
}

static int nonrecursive_large(int value)
{
	return large_helper(value);
}

static long long recursive_total(int depth, long long total)
{
	if (depth == 0) return total;
	return recursive_total(depth - 1, total + add_level(large_helper(depth)));
}

static int even_total(int depth);

static int odd_total(int depth)
{
	if (depth == 0) return 1;
	return add_level(depth) + even_total(depth - 1);
}

static int even_total(int depth)
{
	if (depth == 0) return 0;
	return add_level(depth) + odd_total(depth - 1);
}

int main(void)
{
	/* Keep O0 below the platform stack limit. At 20000 frames the optimized
	   recursion fits an 8 MiB stack with a wide margin only while large_helper
	   stays a call: inlining its 4096-byte scratch would need ~80 MiB and
	   overflow, so the inliner's recursive-caller alloca cap stays covered. */
#ifdef __OPTIMIZE__
	return recursive_total(20000, 0) == 200070000LL &&
		even_total(6) == 39 && nonrecursive_large(23) == 23 ? 0 : 1;
#else
	return recursive_total(10000, 0) == 50035000LL &&
		even_total(6) == 39 && nonrecursive_large(23) == 23 ? 0 : 1;
#endif
}
