/* Recursive quicksort of pseudo-random ints: calls, compares, swaps. */
#include <stdio.h>
#include <stdlib.h>
static void sort(int *v, long lo, long hi)
{
	while (lo < hi)
	{
		int pivot = v[lo + (hi - lo) / 2];
		long i = lo;
		long j = hi;
		while (i <= j)
		{
			while (v[i] < pivot) i++;
			while (v[j] > pivot) j--;
			if (i <= j)
			{
				int t = v[i];
				v[i] = v[j];
				v[j] = t;
				i++;
				j--;
			}
		}
		if (j - lo < hi - i)
		{
			sort(v, lo, j);
			lo = i;
		}
		else
		{
			sort(v, i, hi);
			hi = j;
		}
	}
}
int main(void)
{
	long n = 3000000;
	int *v = malloc(sizeof(int) * n);
	if (!v) return 1;
	unsigned seed = 42;
	for (long i = 0; i < n; i++)
	{
		seed = seed * 1664525u + 1013904223u;
		v[i] = (int)(seed >> 1);
	}
	sort(v, 0, n - 1);
	unsigned long check = 0;
	for (long i = 0; i < n; i++)
	{
		if (i && v[i - 1] > v[i]) return 2;
		check = check * 1099511628211ul + (unsigned)v[i];
	}
	printf("%lu\n", check);
	free(v);
	return 0;
}
