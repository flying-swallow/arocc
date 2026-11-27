// #kind: run
// #exit: 0

#include <limits.h>

static volatile int exercise_min_remainder;
static volatile int exercise_wide_shift;
static volatile int wide_shift_count = sizeof(int) * CHAR_BIT;

int main(void)
{
	int selected = 0 ? 1 : 1 ? 2 : 0 ? 3 : 42;
	if (selected != 2) return 1;

	/* These undefined operations must remain behind their volatile guards. */
	if (exercise_min_remainder) return INT_MIN % -1;
	if (exercise_wide_shift) return 1 << wide_shift_count;
	return 0;
}
