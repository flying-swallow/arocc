// #kind: run
// #exit: 76
static int global_value;

static void mutate_global(int value)
{
	global_value += value;
}

int main(int argc, char **argv)
{
	int for_result = 0;
	int i;
	global_value = argc;
	for (i = 0; i < 3; i++)
		mutate_global(argc + i);
	for_result = global_value;

	int do_value = 0;
	int do_iterations = 0;
	do {
		do_value += argc + do_iterations;
		do_iterations++;
	} while (do_iterations < 3);
	/* With argc == 1, the do/while adds 1, 2, and 3 (three iterations). */

	int branch_result = 0;
	for (i = 0; i < 4; i++) {
		int value = i + argc;
		if (value & 1)
			branch_result += value;
		else
			branch_result += 2 * value;
	}

	int a = argc;
	int b = argc + 1;
	for (i = 0; i < 5; i++) {
		int t = a;
		a = b;
		b = t + b;
	}

	unsigned char counter = 250;
	int wrap_iterations = 0;
	int wrap_result = 0;
	while (counter != 4) {
		counter++;
		wrap_iterations++;
		wrap_result += argc;
	}

	/* For argc == 1: 7 + 6 + 3 + 16 + 13 + 21 + 10 = 76. */
	return for_result + do_value + do_iterations + branch_result + a + b + wrap_result;
}
