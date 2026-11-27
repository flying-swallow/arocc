// #kind: run
// #exit: 144
#include <stdarg.h>
#include <stdio.h>
#include <string.h>

static int vsum(int n, ...)
{
	va_list ap;
	va_start(ap, n);
	int sum = 0;
	for (int i = 0; i < n; i++) sum += va_arg(ap, int);
	va_end(ap);
	return sum;
}

static long vmix(long wide, ...)
{
	va_list ap;
	va_start(ap, wide);
	char *text = va_arg(ap, char *);
	unsigned u = va_arg(ap, unsigned);
	int negative = va_arg(ap, int);
	int promoted_short = va_arg(ap, int);
	int promoted_char = va_arg(ap, int);
	va_end(ap);
	return wide + *text + u + negative + promoted_short + promoted_char;
}

static int vsum_list(int n, va_list ap)
{
	int sum = 0;
	for (int i = 0; i < n; i++) sum += va_arg(ap, int);
	return sum;
}

static int vsum_forward(int n, ...)
{
	va_list ap;
	va_start(ap, n);
	int sum = vsum_list(n, ap);
	va_end(ap);
	return sum;
}

static int copy_twice(int n, ...)
{
	va_list ap;
	va_list copy;
	va_start(ap, n);
	va_copy(copy, ap);
	int first = vsum_list(n, ap);
	int second = vsum_list(n, copy);
	va_end(copy);
	va_end(ap);
	return first + second;
}

/* Keep this call within the backend's current six integer-argument limit. */
static int fmt(char *buf, const char *format, ...)
{
	va_list ap;
	va_start(ap, format);
	int length = vsnprintf(buf, 128, format, ap);
	va_end(ap);
	return length + (strcmp(buf, "27 ok 1234 f") == 0 ? 11 : 0);
}

static int vla_loop(int n, ...)
{
	int scratch[n];
	int total = 0;
	for (int i = 0; i < n; i++) scratch[i] = i;
	va_list ap;
	va_start(ap, n);
	for (int i = 0; i < n; i++) total += va_arg(ap, int) + scratch[i];
	va_end(ap);
	return total;
}

int main(void)
{
	char letter = 'Q';
	char buf[128];
	int failures = 0;
	if (vsum(0) != 0) failures++;
	if (vsum(1, 7) != 7) failures++;
	if (vsum(5, 1, 2, 3, 4, 5) != 15) failures++;
	if (vmix(1000L, &letter, 20U, -3, (short)5, (char)-2) != 1101L) failures++;
	if (vsum_forward(3, 10, 20, 30) != 60) failures++;
	if (copy_twice(3, 10, 20, 30) != 120) failures++;
	if (fmt(buf, "%d %s %ld %x", 27, "ok", 1234L, 15U) != 23) failures++;
	if (vla_loop(3, 4, 5, 6) != 18) failures++;
	int checksum = vsum(0) + vsum(1, 7) + vsum(5, 1, 2, 3, 4, 5) +
		(int)(vmix(1000L, &letter, 20U, -3, (short)5, (char)-2) % 200) +
		vsum_forward(3, 10, 20, 30) + copy_twice(3, 10, 20, 30) +
		fmt(buf, "%d %s %ld %x", 27, "ok", 1234L, 15U) + vla_loop(3, 4, 5, 6);
	return failures * 20 + checksum % 200;
}
