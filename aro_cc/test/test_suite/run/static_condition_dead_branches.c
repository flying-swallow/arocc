// #kind: run
// #exit: 0
// Branches whose condition is known at compile time are not generated (so
// `link_error` stays undefined), like gcc/clang at -O0: folded constants and
// ordered compares against an infinity (gcc ieee/fp-cmp-7.c). Branches that a
// goto or switch can still enter are kept.
extern void link_error(void);

int calls;
double side(void) { calls++; return 1.0; }

int dead_if(double x)
{
	if (0) link_error();
	if (x > __builtin_inf()) link_error();
	if (__builtin_inf() < x) link_error();
	if (x < -__builtin_inf()) link_error();
	if (-__builtin_inf() > x) link_error();
	if (1) return 7; else link_error();
	return 0;
}

int side_effects_kept(void)
{
	// The operand has side effects: the compare stays and is false at run time.
	if (side() > __builtin_inf()) return -1;
	return calls;
}

int goto_into_dead(int n)
{
	if (n) goto inside;
	if (0)
	{
inside:
		return 42;
	}
	return 1;
}

int switch_into_dead(int n)
{
	switch (n)
	{
		if (0)
		{
		case 3:
			return 30;
		}
		default:
			return 0;
	}
}

int main(void)
{
	if (dead_if(1.0) != 7) return 1;
	if (side_effects_kept() != 1) return 2;
	if (goto_into_dead(1) != 42 || goto_into_dead(0) != 1) return 3;
	if (switch_into_dead(3) != 30 || switch_into_dead(1) != 0) return 4;
	return 0;
}
