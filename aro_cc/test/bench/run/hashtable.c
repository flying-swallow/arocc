/* Open-addressing hash table: multiplicative hashing, probing, branches. */
#include <stdio.h>
#include <stdlib.h>
int main(void)
{
	unsigned long cap = 1ul << 22;
	unsigned long *keys = calloc(cap, sizeof(unsigned long));
	unsigned *vals = calloc(cap, sizeof(unsigned));
	if (!keys || !vals) return 1;
	unsigned long x = 88172645463325252ul;
	unsigned inserted = 0;
	for (int i = 0; i < 2000000; i++)
	{
		x ^= x << 13;
		x ^= x >> 7;
		x ^= x << 17;
		unsigned long key = (x % 1500000) + 1;
		unsigned long h = (key * 11400714819323198485ul) >> 42;
		while (keys[h] && keys[h] != key) h = (h + 1) & (cap - 1);
		if (!keys[h])
		{
			keys[h] = key;
			inserted++;
		}
		vals[h]++;
	}
	unsigned long check = inserted;
	for (unsigned long k = 1; k <= 1500000; k += 7)
	{
		unsigned long h = (k * 11400714819323198485ul) >> 42;
		while (keys[h] && keys[h] != k) h = (h + 1) & (cap - 1);
		if (keys[h]) check = check * 31 + vals[h];
	}
	printf("%lu\n", check);
	free(keys);
	free(vals);
	return 0;
}
