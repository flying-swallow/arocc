// #kind: run
// #exit: 28
static int up_lt(void)
{
	int i = 0;
	while (i < 5) i++;
	return i;
}

static int down_ge(void)
{
	int i = 10;
	while (i >= 4) i--;
	return i;
}

static int step_three(void)
{
	int i = 0;
	while (i < 10) i += 3;
	return i;
}

static int do_while_exit(void)
{
	int i = 0;
	do { i++; } while (i < 4);
	return i;
}

static unsigned char unsigned_char_wrap(void)
{
	int iterations = 0;
	for (unsigned char c = 250; c != 4; c++) iterations++;
	return iterations == 10 ? 4 : 0;
}

int main(void)
{
	/* The sum is deliberately below 256 so the run harness sees the exact value. */
	return up_lt() + down_ge() + step_three() + do_while_exit() + unsigned_char_wrap();
}
