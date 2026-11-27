// #kind: run
// #exit: 0

static int recursive_stack_argument(int a, int b, int c, int d,
					     int e, int f, int fixed_stack,
					     int trailing, long double factor)
{
	if (a == 0)
		return b + c + d + e + f + fixed_stack + trailing + (int)(factor * 2.0L);
	return recursive_stack_argument(a - 1, b, c, d, e, f, 7, 8, 1.5L) + 1;
}

int main(void)
{
	/* The seventh and eighth integer arguments, and long double, use the stack. */
	if (recursive_stack_argument(3, 1, 2, 3, 4, 5, 7, 8, 1.5L) != 36) return 1;
	return 0;
}
