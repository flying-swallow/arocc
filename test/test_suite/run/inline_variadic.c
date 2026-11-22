// #kind: run
// #exit: 0
#include <stdarg.h>

static int sum_values(int count, ...)
{
	va_list values;
	va_start(values, count);
	int sum = 0;
	for (int i = 0; i < count; i++) sum += va_arg(values, int);
	va_end(values);
	return sum;
}

/* A variadic function need not use va_start for the inliner to preserve its
   variadic call ABI, including calls that pass otherwise ignored arguments. */
static int fixed_value(int fixed, ...)
{
	return fixed;
}

int main(void)
{
	return sum_values(0) == 0 && sum_values(1, 7) == 7 &&
		sum_values(4, 2, 3, 5, 11) == 21 &&
		fixed_value(13) == 13 && fixed_value(29, 1, 2, 3, 4) == 29 ? 0 : 1;
}
