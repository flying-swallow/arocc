// #kind: run
// #exit: 0
static char global_chars[8];
static short global_shorts[8];
static int global_ints[8];
static long global_longs[8];
static double global_doubles[8];

struct Record {
	char tag;
	int values[5];
	double weight;
};

static struct Record global_record;

/* Keep a nonzero ALLOC offset in the first lowered function. The backend
   reuses its Lowering instance for the following function. */
static int earlier_stack_array(int argc, char **argv)
{
	int values[32] = { 0 };
	values[3] = argc + 9;
	(void)argv;
	return values[3];
}

int main(int argc, char **argv)
{
	char local_chars[8] = { 0 };
	short local_shorts[8] = { 0 };
	int local_ints[8] = { 0 };
	long local_longs[8] = { 0 };
	double local_doubles[8] = { 0 };
	int large[5000] = { 0 };
	struct Record local_record = { 0 };

	global_chars[3] = 17;
	global_shorts[3] = 101;
	global_ints[3] = 1003;
	global_longs[3] = 10003;
	global_doubles[3] = 3.5;
	global_record.values[3] = 31;
	global_record.weight = 4.25;

	local_chars[3] = 19;
	local_shorts[3] = 103;
	local_ints[3] = 1005;
	local_longs[3] = 10007;
	local_doubles[3] = 5.5;
	local_record.values[3] = 37;
	local_record.weight = 6.25;
	large[4001] = 41;

	/* Negative indices and pointer expressions must preserve element scaling. */
	if (*(&global_chars[5] - 2) != 17) return 1;
	if (*(&global_shorts[5] - 2) != 101) return 2;
	if (*(&global_ints[5] - 2) != 1003) return 3;
	if (*(&global_longs[5] - 2) != 10003) return 4;
	if (*(&global_doubles[5] - 2) != 3.5) return 5;
	if (*(&local_chars[5] - 2) != 19) return 6;
	if (*(&local_shorts[5] - 2) != 103) return 7;
	if (*(&local_ints[5] - 2) != 1005) return 8;
	if (*(&local_longs[5] - 2) != 10007) return 9;
	if (*(&local_doubles[5] - 2) != 5.5) return 10;
	if (global_record.values[3] != 31 || global_record.weight != 4.25) return 11;
	if (local_record.values[3] != 37 || local_record.weight != 6.25) return 12;
	if (large[4001] != 41) return 13;
	if (earlier_stack_array(argc, argv) != argc + 9) return 16;
	if (*(3 + &global_ints[0]) != 1003) return 17;

	/* Keep an index live at runtime and exercise both global and stack bases. */
	if (global_ints[argc + 3] != 0) return 14;
	local_longs[argc + 3] = 43;
	if (local_longs[argc + 3] != 43) return 15;
	(void)argv;
	return 0;
}
