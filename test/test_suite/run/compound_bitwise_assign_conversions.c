// #kind: run
// #exit: 0
// `%=`, `&=`, `^=` and `|=` apply the usual arithmetic conversions to both
// operands (csmith seed 144: `uint64 |= int32 -1` must sign-extend).
#include <stdint.h>
static int32_t minus_one(void) { return -1; }
int main(void)
{
	uint64_t a = 0x9565E08CCCDDD1D8ULL;
	a |= minus_one();
	if (a != UINT64_MAX) return 1;
	uint64_t b = UINT64_MAX;
	int32_t m = -16;
	b &= m;
	if (b != 0xFFFFFFFFFFFFFFF0ULL) return 2;
	uint64_t c = 0;
	c ^= (int8_t)-1;
	if (c != UINT64_MAX) return 3;
	unsigned u = 7;
	int i = -2;
	u %= i; // -2 converts to 0xFFFFFFFE: 7 % 4294967294 == 7
	if (u != 7) return 4;
	long long ll = 100;
	unsigned short us = 7;
	ll %= us;
	if (ll != 2) return 5;
	uint8_t s = 0x80;
	s <<= 1L; // shifts keep the left operand's (promoted) type
	if (s != 0) return 6;
	return 0;
}
