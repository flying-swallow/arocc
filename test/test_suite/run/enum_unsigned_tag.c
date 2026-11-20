// #kind: run
// #exit: 0
/* Enum signedness follows the underlying tag type: an enum whose values are
   all non-negative has tag `unsigned int`, so bit-field reads, widening,
   compares and shifts are unsigned (gcc.c-torture/execute/20030714-1.c).
   Returns a failure bitmask. */
enum EPosition { STATIC, RELATIVE, ABSOLUTE, FIXED };
enum Big { ZERO = 0, BIG = 0x80000000u };
enum Signed { NEG = -1, POS = 1 };

struct Flags { enum EPosition pos : 2; enum Signed s : 2; } flags;
enum Big big = BIG;

int main(void)
{
	int fail = 0;
	flags.pos = FIXED;
	flags.s = NEG;
	if (flags.pos != FIXED) fail |= 1;
	if ((int)flags.pos != 3) fail |= 2;
	if (flags.s != NEG) fail |= 4;
	long l = big;
	unsigned long long u = big;
	if (l != 2147483648L) fail |= 8;
	if (u != 2147483648ULL) fail |= 16;
	if (!(big > 0)) fail |= 32;
	if ((big >> 31) != 1) fail |= 64;
	switch (flags.pos)
	{
		case FIXED: break;
		default: fail |= 128;
	}
	return fail;
}
