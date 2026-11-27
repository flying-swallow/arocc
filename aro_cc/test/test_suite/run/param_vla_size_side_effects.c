// #kind: run
// #exit: 0
// C11 6.9.1p10: a variably modified parameter's size expressions are
// evaluated on function entry, side effects included (gcc 970217-1, pr77767).
int sub(int i, int array[i++]) { return i; }

int calls;
int next(void) { return ++calls; }
int both(int n, int (*p)[n++], int a[next()][n]) { return n * 100 + calls; }

int unspecified(int n, int a[*]);
int unspecified(int n, int a[n++]) { return n; }

int sized(int n, int a[n]) { return (int)sizeof(*(int (*)[n])a) + n; }

int main(void)
{
	int x[20];
	if (sub(10, x) != 11) return 1;
	int (*row)[3] = 0;
	if (both(3, row, 0) != 401) return 2;
	if (unspecified(5, x) != 6) return 3;
	if (sized(4, x) != 20) return 4;
	return 0;
}
