// #kind: run
// #exit: 0

static int scale(int count, int factor) {
	if (count == 0) return 0;
	return factor + scale(count - 1, 7);
}

static int status(int condition) {
	if (condition == 0) return 42;
	return 42;
}

int main(void) {
	if (scale(6, 7) != 42) return 1;
	if (status(0) != 42) return 2;
	if (status(1) != 42) return 3;
	return 0;
}
