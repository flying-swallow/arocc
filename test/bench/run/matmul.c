/* Integer matrix multiply: 2D indexing, inner-loop multiply-add. */
#include <stdio.h>
#include <stdlib.h>
int main(void)
{
	int n = 400;
	int *a = malloc(sizeof(int) * n * n);
	int *b = malloc(sizeof(int) * n * n);
	int *c = malloc(sizeof(int) * n * n);
	if (!a || !b || !c) return 1;
	for (int i = 0; i < n * n; i++)
	{
		a[i] = (i * 7 + 3) % 101;
		b[i] = (i * 13 + 5) % 97;
	}
	for (int i = 0; i < n; i++)
		for (int j = 0; j < n; j++)
		{
			int sum = 0;
			for (int k = 0; k < n; k++) sum += a[i * n + k] * b[k * n + j];
			c[i * n + j] = sum;
		}
	unsigned long check = 0;
	for (int i = 0; i < n * n; i++) check = check * 31 + (unsigned)c[i];
	printf("%lu\n", check);
	free(a);
	free(b);
	free(c);
	return 0;
}
