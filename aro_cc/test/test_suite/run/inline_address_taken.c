// #kind: run
// #exit: 0

static inline int adjust(int value)
{
	return value * 3 + 2;
}

static inline int call_adjust(int value)
{
	return adjust(value) + 1;
}

int main(void)
{
	int (* volatile indirect)(int) = adjust;
	int (* volatile indirect_caller)(int) = call_adjust;
	return indirect(7) == 23 && call_adjust(5) == 18 &&
		indirect_caller(7) == 24 ? 0 : 1;
}
