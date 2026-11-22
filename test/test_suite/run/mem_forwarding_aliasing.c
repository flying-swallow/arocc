// #kind: run
// #exit: 0

int main(void)
{
	int a[4];
	a[1] = 17;
	a[2] = 29;
	a[0] = 0;
	a[1] = 43;
	int index = 1;
	a[index] = 71;
	if (a[1] != 71) return 1;

	int joined = 0;
	if (index) joined = 83;
	else joined = 97;
	if (joined != 83) return 2;

	volatile int device = 109;
	if (device != 109) return 3;
	return 0;
}
