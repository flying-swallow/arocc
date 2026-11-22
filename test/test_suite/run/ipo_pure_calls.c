// #kind: run
// #exit: 0
#define NOINLINE __attribute__((noinline))

static int state;
static volatile int volatile_value = 7;

static int unused_pure_helper(void)
{
	return 42;
}

static void write_global(void)
{
	state = 3;
}

static int read_volatile_global(void)
{
	return volatile_value;
}

static NOINLINE int may_trap(int should_trap)
{
	if (should_trap) __builtin_trap();
	return 21;
}

static int mutual_b(int depth);

static NOINLINE int mutual_a(int depth)
{
	if (depth == 0) return 20;
	return mutual_b(depth - 1) + 1;
}

static NOINLINE int mutual_b(int depth)
{
	if (depth == 0) return 20;
	return mutual_a(depth - 1) + 1;
}

int main(void)
{
	/* The result is unused, so IPO may remove this call. */
	unused_pure_helper();
	write_global();
	if (may_trap(0) != 21) return 1;
	if (mutual_a(2) != 22) return 2;
	return state == 3 && read_volatile_global() == 7 ? 0 : 3;
}
