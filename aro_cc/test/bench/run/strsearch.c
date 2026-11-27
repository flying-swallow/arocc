/* Naive substring counting over generated text: byte loads and compares. */
#include <stdio.h>
#include <stdlib.h>
static long count_matches(const char *text, long n, const char *pat, long m)
{
	long hits = 0;
	for (long i = 0; i + m <= n; i++)
	{
		long j = 0;
		while (j < m && text[i + j] == pat[j]) j++;
		if (j == m) hits++;
	}
	return hits;
}
int main(void)
{
	long n = 32l << 20;
	char *text = malloc((size_t)n);
	if (!text) return 1;
	unsigned seed = 7;
	for (long i = 0; i < n; i++)
	{
		seed = seed * 1103515245u + 12345u;
		text[i] = (char)('a' + (seed >> 16) % 4);
	}
	char pat[8];
	for (int i = 0; i < 7; i++) pat[i] = (char)('a' + (i * 3) % 4);
	pat[7] = 0;
	printf("%ld\n", count_matches(text, n, pat, 7));
	free(text);
	return 0;
}
