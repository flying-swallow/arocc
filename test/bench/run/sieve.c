/* Sieve of Eratosthenes: byte array stores, nested loops. */
#include <stdio.h>
#include <stdlib.h>
int main(void)
{
	int n = 20000000;
	char *composite = calloc((size_t)n + 1, 1);
	if (!composite) return 1;
	int count = 0;
	for (int i = 2; i <= n; i++)
	{
		if (composite[i]) continue;
		count++;
		for (long j = (long)i * i; j <= n; j += i) composite[j] = 1;
	}
	printf("%d\n", count);
	free(composite);
	return 0;
}
