// #kind: run
// #exit: 0
/* Exercise short-circuit, conditional, nested branch, and loop-flag paths. */
static int and_path(int a, int b) { return a && b; }
static int or_path(int a, int b) { return a || b; }
static int conditional_path(int a, int b) { return a ? (b ? 3 : 4) : (b ? 5 : 6); }
static int effect_calls;
static int effect(int value) { effect_calls++; return value; }

static int nested_path(int a, int b, int c)
{
	if (a) {
		if (b) return 11;
		return 12;
	}
	if (c) return 13;
	return 14;
}

/* flag is loop-carried through a PHI after optimization. */
static int loop_flag(int n, int stop)
{
	int flag = 0;
	for (int i = 0; i < n; i++) {
		if (i == stop) flag = 1;
		if (flag && i > stop) return i;
	}
	return flag;
}

int main(void)
{
	int failures = 0;
	int grid[] = { -1, 0, 1 };
	for (int i = 0; i < 3; i++) {
		int a = grid[i];
		for (int j = 0; j < 3; j++) {
			int b = grid[j];
			if (and_path(a, b) != (!!a && !!b)) failures |= 1;
			if (or_path(a, b) != (!!a || !!b)) failures |= 2;
			effect_calls = 0;
			int and_effect = effect(a) && effect(b);
			if (and_effect != (!!a && !!b) || effect_calls != (a ? 2 : 1)) failures |= 32;
			effect_calls = 0;
			int or_effect = effect(a) || effect(b);
			if (or_effect != (!!a || !!b) || effect_calls != (a ? 1 : 2)) failures |= 64;
			int expected = a ? (b ? 3 : 4) : (b ? 5 : 6);
			if (conditional_path(a, b) != expected) failures |= 4;
			for (int k = 0; k < 3; k++) {
				int c = grid[k];
				int nested_expected = a ? (b ? 11 : 12) : (c ? 13 : 14);
				if (nested_path(a, b, c) != nested_expected) failures |= 8;
			}
		}
	}
	for (int n = 0; n <= 8; n++) {
		for (int stop = -1; stop <= 9; stop++) {
			int expected = 0;
			if (stop >= 0 && stop < n) expected = stop + 1 < n ? stop + 1 : 1;
			if (loop_flag(n, stop) != expected) failures |= 16;
		}
	}
	return failures;
}
