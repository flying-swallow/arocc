// #kind: run
// #exit: 0
/* Exercise variadic retrieval of alternating integer and promoted double
   arguments, including a copied va_list that traverses the same values. */
#include <stdarg.h>

static double sum_pairs_list(int pairs, va_list args)
{
	double sum = 0.0;
	for (int i = 0; i < pairs; i++)
	{
		sum += va_arg(args, int);
		sum += va_arg(args, double);
	}
	return sum;
}

static double sum_pairs(int pairs, ...)
{
	va_list args;
	va_start(args, pairs);
	double sum = sum_pairs_list(pairs, args);
	va_end(args);
	return sum;
}

static double sum_pairs_twice(int pairs, ...)
{
	va_list args;
	va_list copy;
	va_start(args, pairs);
	va_copy(copy, args);
	double first = sum_pairs_list(pairs, args);
	double second = sum_pairs_list(pairs, copy);
	va_end(copy);
	va_end(args);
	return first + second;
}

int main(void)
{
	int failures = 0;
	if (sum_pairs(2, 10, 0.5, -3, 1.25) != 8.75) failures++;
	if (sum_pairs_twice(2, 1, 0.25, 2, 0.75) != 8.0) failures++;
	return failures;
}
