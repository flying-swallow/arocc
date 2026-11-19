// #kind: run
// #exit: 0
#include <stdarg.h>
#include <stdio.h>
#include <string.h>

static long double mixed_values(int first, double second, long double third,
	unsigned long fourth, float fifth, long double sixth)
{
	return (long double)first + (long double)second + third +
		(long double)fourth + (long double)fifth + sixth;
}

static long double identity_long_double(long double value)
{
	return value;
}

static long double sum_variadic(int count, ...)
{
	va_list ap;
	va_start(ap, count);
	long double total = 0.0L;
	for (int i = 0; i < count; i++) total += va_arg(ap, long double);
	va_end(ap);
	return total;
}

int main(void)
{
	int failures = 0;
	long double mixed = mixed_values(3, 1.5, 2.25L, 4UL, 0.5f, 0.75L);
	if (mixed != 12.0L) failures++;
	if (identity_long_double(7.125L) != 7.125L) failures++;
	if (sum_variadic(3, 1.25L, 2.5L, 3.0L) != 6.75L) failures++;

	char output[64];
	int length = snprintf(output, sizeof output, "value=%.2Lf", 12.5L);
	if (length != 11 || strcmp(output, "value=12.50") != 0) failures++;
	return failures;
}
