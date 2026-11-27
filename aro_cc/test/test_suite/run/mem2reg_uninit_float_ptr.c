// #kind: run
// #exit: 0

static double choose_initialized_value(int c)
{
	double d;
	if (c) d = 1.5;
	else d = 2.5;
	return d;
}

int main(void)
{
	if (choose_initialized_value(1) != 1.5) return 1;
	if (choose_initialized_value(0) != 2.5) return 2;
	return 0;
}
