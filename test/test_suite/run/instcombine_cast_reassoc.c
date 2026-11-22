// #kind: run
// #exit: 0
// #opt: -w

#include <limits.h>

#define NOINLINE __attribute__((noinline))

static NOINLINE int signed_char_round_trip(int x)
{
	signed char narrowed = (signed char)x;
	return (int)(signed char)(int)narrowed;
}

static NOINLINE int plain_char_round_trip(int x)
{
	char narrowed = (char)x;
	return (int)(char)(int)narrowed;
}

static NOINLINE int signed_short_round_trip(int x)
{
	short narrowed = (short)x;
	return (int)(short)(int)narrowed;
}

static NOINLINE long signed_long_round_trip(long x)
{
	long narrowed = (long)(int)x;
	return (long)(int)narrowed;
}

static NOINLINE unsigned char unsigned_char_wrap(unsigned char x)
{
	return (x + 200u) + 100u;
}

static NOINLINE unsigned int subtract_loop(unsigned int x)
{
	unsigned int count = 0;
	while (x >= 2u) {
		x = (x - 1u) - 1u;
		count += 2u;
	}
	return count + x;
}

static NOINLINE unsigned int xor_involution(unsigned int x, unsigned int mask)
{
	return (x ^ mask) ^ mask;
}

static NOINLINE unsigned char mixed_signed_unsigned(signed char s, unsigned int u)
{
	return (unsigned char)(s + u);
}

int main(void)
{
	int failures = 0;
	if (signed_char_round_trip(-128) != -128 ||
		signed_char_round_trip(-1) != -1 ||
		signed_char_round_trip(0x80) != -128 ||
		signed_char_round_trip(0xff) != -1 ||
		signed_char_round_trip(0) != 0 ||
		signed_char_round_trip(127) != 127)
		failures |= 1;

	if (plain_char_round_trip(-1) != -1 ||
		plain_char_round_trip(0) != 0 ||
		plain_char_round_trip(0x7f) != 0x7f ||
		plain_char_round_trip(0x80) != (int)(char)0x80 ||
		plain_char_round_trip(0xff) != (int)(char)0xff)
		failures |= 64;

	if (signed_short_round_trip(-32768) != -32768 ||
		signed_short_round_trip(-1) != -1 ||
		signed_short_round_trip(0) != 0 ||
		signed_short_round_trip(0x7fff) != 0x7fff)
		failures |= 128;

	if (signed_long_round_trip(-32768L) != -32768L ||
		signed_long_round_trip(-1L) != -1L ||
		signed_long_round_trip(0L) != 0L ||
		signed_long_round_trip(32767L) != 32767L)
		failures |= 256;

	if ((int)(unsigned char)INT_MIN != 0 ||
		(int)(unsigned char)INT_MAX != 255 ||
		(unsigned char)0x80 != 128 || (unsigned char)0xff != 255)
		failures |= 2;

	if (unsigned_char_wrap(0) != 44 ||
		unsigned_char_wrap(1) != 45 ||
		unsigned_char_wrap(0x80) != 172 ||
		unsigned_char_wrap(255) != 43)
		failures |= 4;

	if (subtract_loop(0u) != 0u || subtract_loop(1u) != 1u ||
		subtract_loop(2u) != 2u || subtract_loop(73u) != 73u)
		failures |= 8;

	if (xor_involution(0x12345678u, 0xa5a5a5a5u) != 0x12345678u ||
		xor_involution(UINT_MAX, 0x55u) != UINT_MAX)
		failures |= 16;

	if (mixed_signed_unsigned(-1, 2u) != 1 ||
		mixed_signed_unsigned(-128, 0u) != 128 ||
		mixed_signed_unsigned(-2, 1u) != 255 ||
		mixed_signed_unsigned(127, UINT_MAX) != 126)
		failures |= 32;

	return failures;
}
