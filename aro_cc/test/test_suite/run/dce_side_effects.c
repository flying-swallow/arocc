// #kind: run
// #exit: 0

static int call_count;
static volatile int volatile_divisor = 3;
static volatile int volatile_global = 17;

static int increment_call_count(void)
{
	call_count++;
	return call_count;
}

static int exercise_volatile_member(void)
{
	struct Local {
		volatile int value;
	};
	struct Local local;
	local.value = 41;
	return local.value;
}

int main(void)
{
	int numerator = 19;
	int result;

	increment_call_count();
	if (call_count != 1) return 1;

	result = numerator / volatile_divisor;
	(void)result;

	result = volatile_global;
	(void)result;

	if (exercise_volatile_member() != 41) return 2;
	return 0;
}
