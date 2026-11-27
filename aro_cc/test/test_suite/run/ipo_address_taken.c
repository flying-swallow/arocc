// #kind: run
// #exit: 0

static int choose_value(int value, int ignored)
{
	if (value == 0) return ignored;
	return choose_value(value - 1, ignored + 2);
}

static int (*volatile choose_pointer)(int, int) = choose_value;

int main(void)
{
	if (choose_value(11, 3) != 25) return 1;
	if (choose_pointer(23, 7) != 53) return 2;
	return 0;
}
