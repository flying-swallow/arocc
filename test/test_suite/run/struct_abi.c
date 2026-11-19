// #kind: run
// #exit: 0
// #opt: -w
/* SysV x86-64 INTEGER and MEMORY classification for aggregate arguments and
   returns. Keep the callees out of line so the calls exercise the ABI. */
#define NOINLINE __attribute__((noinline))

/* Match the standard layouts and libc prototypes while keeping the case
   independent of host header diagnostics. */
typedef struct { int quot, rem; } div_t;
typedef struct { long quot, rem; } ldiv_t;
extern div_t div(int numerator, int denominator);
extern ldiv_t ldiv(long numerator, long denominator);

struct R4 { unsigned int value; };
struct R8 { unsigned int first, second; };
struct R12 { unsigned int first, second, third; };
struct R16 { unsigned long first, second; };
struct R24 { unsigned char bytes[24]; };
struct R100 { unsigned char bytes[100]; };

union U8 { unsigned long word; struct { unsigned int first, second; } halves; };
union U16 { struct R16 pair; unsigned char bytes[16]; };

static NOINLINE struct R4 make4(unsigned int value)
{
	struct R4 result = { value };
	return result;
}

static NOINLINE struct R8 make8(unsigned int value)
{
	struct R8 result = { value, value + 1 };
	return result;
}

static NOINLINE struct R12 make12(unsigned int value)
{
	struct R12 result = { value, value + 1, value + 2 };
	return result;
}

static NOINLINE struct R16 make16(unsigned long value, unsigned long second)
{
	struct R16 result = { value, second };
	return result;
}

static NOINLINE struct R24 make24(unsigned char seed)
{
	struct R24 result;
	for (int i = 0; i < 24; i++) result.bytes[i] = (unsigned char)(seed + i);
	return result;
}

static NOINLINE struct R100 make100(unsigned char seed)
{
	struct R100 result;
	for (int i = 0; i < 100; i++) result.bytes[i] = (unsigned char)(seed + i);
	return result;
}

static NOINLINE union U8 make_u8(unsigned long value)
{
	union U8 result;
	result.word = value;
	return result;
}

static NOINLINE union U16 make_u16(unsigned long first, unsigned long second)
{
	union U16 result;
	result.pair.first = first;
	result.pair.second = second;
	return result;
}

static NOINLINE unsigned long take4(struct R4 value)
{
	return value.value;
}

static NOINLINE unsigned long take8(struct R8 value)
{
	return (unsigned long)value.first * 10 + value.second;
}

static NOINLINE unsigned long take12(struct R12 value)
{
	return (unsigned long)value.first * 100 + value.second * 10 + value.third;
}

static NOINLINE unsigned long take16(struct R16 value)
{
	return value.first * 10 + value.second;
}

static NOINLINE unsigned long take_u8(union U8 value)
{
	return value.word;
}

static NOINLINE unsigned long take_u16(union U16 value)
{
	return value.pair.first * 10 + value.pair.second;
}

static NOINLINE unsigned long exhausted_gp(long a, long b, long c, long d, long e,
		struct R16 pair, long tail)
{
	return (unsigned long)(a + 10 * b + 100 * c + 1000 * d + 10000 * e) +
		pair.first * 100000 + pair.second * 1000000 + (unsigned long)tail * 10000000;
}

/* These three large aggregates and the interleaved scalars are all stack
   arguments once the six INTEGER registers have been consumed. The writes
   must affect only the callee's by-value copies. */
static NOINLINE unsigned long stack_copies(long a, long b, long c, long d, long e, long f,
		struct R24 first, long x, struct R100 middle, long y,
		struct R24 last, long z)
{
	first.bytes[0] += 1;
	middle.bytes[0] += 2;
	last.bytes[23] -= 3;
	return (unsigned long)(a + 10 * b + 100 * c + 1000 * d + 10000 * e + 100000 * f) +
		(unsigned long)first.bytes[0] + (unsigned long)x * 10 +
		(unsigned long)middle.bytes[0] * 100 + (unsigned long)y * 1000 +
		(unsigned long)last.bytes[23] * 10000 + (unsigned long)z * 100000;
}

static NOINLINE struct R16 recursive16(unsigned int depth, unsigned long seed)
{
	if (depth == 0) return make16(seed, seed + 1);
	struct R16 result = recursive16(depth - 1, seed + 2);
	result.first += 1;
	result.second += 3;
	return result;
}

static NOINLINE unsigned long sum16(struct R16 value)
{
	return value.first + value.second;
}

int main(void)
{
	int failures = 0;

	struct R4 r4 = make4(17);
	struct R8 r8 = make8(23);
	struct R12 r12 = make12(31);
	struct R16 r16 = make16(41, 43);
	failures += (sizeof r4 == 4 && r4.value == 17 &&
		sizeof r8 == 8 && r8.first == 23 && r8.second == 24 &&
		sizeof r12 == 12 && r12.first == 31 && r12.second == 32 && r12.third == 33 &&
		sizeof r16 == 16 && r16.first == 41 && r16.second == 43) ? 0 : 1;

	failures += (take4(r4) == 17) ? 0 : 2;
	failures += (take8(r8) == 254) ? 0 : 4;
	failures += (take12(r12) == 3453) ? 0 : 8;
	failures += (take16(r16) == 453) ? 0 : 16;

	union U8 u8 = make_u8(0x123456789abcdef0UL);
	union U16 u16 = make_u16(47, 53);
	failures += (sizeof u8 == 8 && take_u8(u8) == 0x123456789abcdef0UL &&
		sizeof u16 == 16 && take_u16(u16) == 523) ? 0 : 4;

	/* A two-eightbyte argument cannot use the one remaining GP register. It
	   must spill as a whole, leaving that register for tail. */
	struct R16 pair = { 7, 11 };
	unsigned long exhausted = exhausted_gp(1, 2, 3, 4, 5, pair, 13);
	failures += (exhausted == 141754321) ? 0 : 8;

	struct R24 first = make24(10);
	struct R100 middle = make100(30);
	struct R24 last = make24(50);
	unsigned long stack_result = stack_copies(1, 2, 3, 4, 5, 6,
		first, 7, middle, 8, last, 9);
	unsigned long stack_again = stack_copies(1, 2, 3, 4, 5, 6,
		first, 7, middle, 8, last, 10);
	int copies_intact = 1;
	for (int i = 0; i < 24; i++) {
		copies_intact &= first.bytes[i] == (unsigned char)(10 + i);
		copies_intact &= last.bytes[i] == (unsigned char)(50 + i);
	}
	for (int i = 0; i < 100; i++)
		copies_intact &= middle.bytes[i] == (unsigned char)(30 + i);
	failures += (sizeof first == 24 && sizeof middle == 100 &&
		stack_result == 2265602 && stack_again == 2365602 && copies_intact) ? 0 : 16;

	/* Aggregate calls remain present in member access, initialization, nested
	   calls, and a conditional expression. */
	unsigned long returned_member = make16(61, 67).second;
	struct R16 initialized_from_call = make16(71, 73);
	unsigned long nested_call = sum16(make16(79, 83));
	volatile int choose_left = 1;
	struct R16 conditional = choose_left ? make16(89, 97) : make16(101, 103);
	failures += (returned_member == 67 && initialized_from_call.first == 71 &&
		initialized_from_call.second == 73 && nested_call == 162 &&
		conditional.first == 89 && conditional.second == 97) ? 0 : 32;

	struct R16 (* volatile returning_function)(unsigned long, unsigned long) = make16;
	struct R16 through_pointer = returning_function(107, 109);
	failures += (through_pointer.first == 107 && through_pointer.second == 109) ? 0 : 64;

	struct R16 recursive = recursive16(4, 113);
	failures += (recursive.first == 125 && recursive.second == 134) ? 0 : 128;

	div_t (* volatile libc_div)(int, int) = div;
	ldiv_t (* volatile libc_ldiv)(long, long) = ldiv;
	div_t quotient_remainder = libc_div(71, 9);
	ldiv_t long_quotient_remainder = libc_ldiv(101, 12);
	failures += (sizeof quotient_remainder == 8 && quotient_remainder.quot == 7 &&
		quotient_remainder.rem == 8 && sizeof long_quotient_remainder == 16 &&
		long_quotient_remainder.quot == 8 && long_quotient_remainder.rem == 5) ? 0 : 256;

	/* Check both sret results, including all bytes and a call after stack args. */
	struct R24 returned24 = make24(140);
	struct R100 returned100 = make100(3);
	int memory_returns_ok = 1;
	for (int i = 0; i < 24; i++)
		memory_returns_ok &= returned24.bytes[i] == (unsigned char)(140 + i);
	for (int i = 0; i < 100; i++)
		memory_returns_ok &= returned100.bytes[i] == (unsigned char)(3 + i);
	failures += memory_returns_ok ? 0 : 512;

	return failures != 0;
}
