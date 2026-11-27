// #kind: run
// #exit: 0

static int *captured_pointer;

/* Keep direct calls so the interprocedural summaries drive memory optimization. */
#define NOINLINE __attribute__((noinline))
static NOINLINE int read_value(const int *pointer)
{
	return *pointer;
}

static NOINLINE void write_value(int *pointer, int value)
{
	*pointer = value;
}

static NOINLINE void capture_pointer(int *pointer)
{
	captured_pointer = pointer;
}

int main(void)
{
	int values[2] = { 11, 23 };

	if (read_value(&values[0]) != 11) return 1;
	write_value(&values[0], 37);
	if (read_value(&values[0]) != 37) return 2;

	/* The callee retains the pointer; the subsequent store goes through it. */
	capture_pointer(&values[1]);
	*captured_pointer = 49;
	if (values[1] != 49 || read_value(&values[1]) != 49) return 3;

	values[1] = 61;
	if (*captured_pointer != 61) return 4;
	return 0;
}
