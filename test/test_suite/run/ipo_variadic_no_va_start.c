// #kind: run
// #exit: 0

static int variadic_fixed(int fixed, ...)
{
	return fixed + 1;
}

static volatile int side_effects;

static int side_effect(int value)
{
	side_effects++;
	return value;
}

int main(void)
{
	if (variadic_fixed(10) != 11) return 1;
	if (variadic_fixed(10) != 11) return 2;
	if (variadic_fixed(40, side_effect(1)) != 41) return 3;
	if (side_effects != 1) return 4;
	if (variadic_fixed(40, 1) != 41) return 5;
	return 0;
}
