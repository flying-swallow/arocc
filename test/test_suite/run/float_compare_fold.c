// #kind: run
// #exit: 0
/* Constant-folded float compares follow IEEE, not value identity: a folded
   NaN is unequal to itself (gcc.c-torture/execute/ieee/fp-cmp-6.c) and
   +0.0 == -0.0. Returns a failure bitmask. */
const double dnan = 1.0 / 0.0 - 1.0 / 0.0;
double x = 1.0;
int zero_arr[(0.0 == -0.0) ? 1 : 2];

int main(void)
{
	int fail = 0;
	if (dnan == dnan) fail |= 1;
	if (!(dnan != dnan)) fail |= 2;
	if (dnan <= dnan || dnan >= dnan) fail |= 4;
	if (dnan < x || dnan > x || dnan == x) fail |= 8;
	if (!(0.0 == -0.0) || (0.0 != -0.0)) fail |= 16;
	if (sizeof zero_arr != sizeof(int)) fail |= 32;
	return fail;
}
