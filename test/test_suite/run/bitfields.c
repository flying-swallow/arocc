// #kind: run
// #exit: 213
/* Bitfield reads and writes in regular, mixed, and packed records, including
   a field that crosses an unsigned-int allocation boundary. */
struct RegularBits {
	unsigned int first : 3;
	unsigned int shifted : 9;
	signed int signed_value : 6;
	unsigned int last : 4;
	unsigned char neighbor;
	int plain;
};

struct __attribute__((packed)) PackedBits {
	unsigned int first : 5;
	unsigned int straddling : 30;
	signed int signed_value : 7;
	unsigned int last : 6;
	unsigned char neighbor;
	unsigned char trailer;
};

struct WrapBits {
	unsigned int value : 3;
	unsigned int neighbor : 3;
};

struct MixedBits {
	int a : 3;
	unsigned b : 5;
	int c : 7;
	unsigned d : 1;
	_Bool e : 1;
	long long w : 40;
	char ch;
};

struct RegularBits global_regular = { 6, 0x12d, -17, 9, 0xa5, 771 };
struct PackedBits global_packed = { 19, 0x2345678, -37, 45, 0xc3, 0x5a };
struct MixedBits global_mixed = { -4, 0x1b, -53, 1, 2, 0x123456789aLL, 'G' };

static int take_bits(int a, int b, unsigned int c)
{
	return a * 16 + b * 2 + (int)c;
}

static int fold(int checksum, int value)
{
	return (checksum * 33 + value) & 255;
}

int main(void)
{
	int bad = 0;
	unsigned int oversized = 0xffffffffu;
	int overwide_first = 0x2f;
	struct RegularBits regular = { 5, 0x12d, -9, 11, 0xa5, 1001 };
	struct PackedBits packed = { 17, 0x2abcde, -23, 41, 0xd3, 0x6b };
	struct PackedBits *ptr = &packed;
	struct WrapBits wrap = { 7, 5 };
	struct MixedBits mixed = { -3, 0x15, -41, 1, 2, 0x23456789abLL, 'M' };
	int assignment_value;
	int post_increment;
	int pre_increment;
	int post_decrement;
	int pre_decrement;
	int call_result;
	int checksum = 0;

#define CHECK(condition, bit) do { if (!(condition)) bad |= (bit); } while (0)

	/* Local aggregate initialization, shifted extraction, and sign extension. */
	CHECK(regular.first == 5 && regular.shifted == 0x12d &&
		(regular.shifted >> 3) == 0x25 && regular.signed_value == -9 &&
		(regular.signed_value >> 1) == -5 && regular.last == 11 &&
		regular.neighbor == 0xa5 && regular.plain == 1001, 1);

	/* `straddling` starts at bit 5 and crosses a 32-bit boundary. */
	CHECK(ptr->first == 17 && ptr->straddling == 0x2abcde &&
		(ptr->straddling >> 8) == 0x2abc && ptr->signed_value == -23 &&
		(ptr->signed_value >> 2) == -6 && ptr->last == 41 &&
		ptr->neighbor == 0xd3 && ptr->trailer == 0x6b &&
		sizeof(struct PackedBits) >= 8, 2);

	/* Narrow writes truncate while preserving the fields on either side. */
	ptr->straddling = oversized;
	CHECK(ptr->straddling == 0x3fffffffu && ptr->first == 17 &&
		ptr->signed_value == -23 && ptr->last == 41 && ptr->neighbor == 0xd3 &&
		ptr->trailer == 0x6b, 4);

	/* Compound operations on packed bitfields and a bitfield assignment value. */
	ptr->straddling = 0x12345;
	ptr->straddling += 7;
	ptr->straddling <<= 2;
	ptr->straddling -= 0x30;
	ptr->straddling *= 2;
	ptr->straddling |= 0x55;
	ptr->signed_value += 5;
	ptr->last ^= 0x3f;
	assignment_value = (ptr->first = overwide_first);
	CHECK(ptr->straddling == 0x91a55 && ptr->signed_value == -18 &&
		ptr->last == 22 && ptr->first == 15 && assignment_value == 15 &&
		ptr->neighbor == 0xd3 && ptr->trailer == 0x6b, 8);

	/* Mixed signed, unsigned, boolean, and wide fields share one record. */
	mixed.e = 0;
	CHECK(!mixed.e && mixed.d == 1, 128);
	mixed.e = 2;
	CHECK(mixed.a == -3 && mixed.b == 0x15 && mixed.c == -41 && mixed.d == 1 &&
		mixed.e == 1 && mixed.w == 0x23456789abLL && mixed.ch == 'M' &&
		global_mixed.a == -4 && global_mixed.b == 0x1b &&
		global_mixed.c == -53 && global_mixed.d == 1 && global_mixed.e == 1 &&
		global_mixed.w == 0x123456789aLL && global_mixed.ch == 'G', 128);

	/* Post and pre forms wrap at both ends of this unsigned three-bit field. */
	post_increment = wrap.value++;
	pre_increment = ++wrap.value;
	post_decrement = wrap.value--;
	pre_decrement = --wrap.value;
	CHECK(post_increment == 7 && pre_increment == 1 && post_decrement == 1 &&
		pre_decrement == 7 && wrap.value == 7 && wrap.neighbor == 5, 16);

	/* Bitfields participate in arithmetic, comparisons, and ordinary calls. */
	call_result = take_bits(regular.signed_value, ptr->signed_value, ptr->last);
	CHECK(regular.signed_value < 0 && ptr->signed_value < 0 &&
		ptr->last > ptr->first &&
		call_result == -158 &&
		(regular.shifted + ptr->last) == 323, 32);

	/* Global bitfield initializers exercise both layouts. */
	CHECK(global_regular.first == 6 && global_regular.shifted == 0x12d &&
		global_regular.signed_value == -17 && global_regular.last == 9 &&
		global_regular.neighbor == 0xa5 && global_regular.plain == 771 &&
		global_packed.first == 19 && global_packed.straddling == 0x2345678 &&
		global_packed.signed_value == -37 && global_packed.last == 45 &&
		global_packed.neighbor == 0xc3 && global_packed.trailer == 0x5a, 64);

	checksum = fold(checksum, regular.first);
	checksum = fold(checksum, regular.shifted);
	checksum = fold(checksum, regular.signed_value);
	checksum = fold(checksum, regular.last);
	checksum = fold(checksum, regular.neighbor);
	checksum = fold(checksum, regular.plain);
	checksum = fold(checksum, ptr->first);
	checksum = fold(checksum, ptr->straddling);
	checksum = fold(checksum, ptr->signed_value);
	checksum = fold(checksum, ptr->last);
	checksum = fold(checksum, ptr->neighbor);
	checksum = fold(checksum, mixed.a + mixed.b + mixed.c + mixed.d + mixed.e +
		(int)(mixed.w & 255) + mixed.ch);
	checksum = fold(checksum, global_mixed.a + global_mixed.b + global_mixed.c +
		global_mixed.d + global_mixed.e + (int)(global_mixed.w & 255) +
		global_mixed.ch);
	checksum = fold(checksum, assignment_value);
	checksum = fold(checksum, post_increment + pre_increment +
		post_decrement + pre_decrement + wrap.value + wrap.neighbor);
	checksum = fold(checksum, call_result);
	checksum = fold(checksum, global_regular.first + global_regular.shifted +
		global_regular.signed_value + global_regular.last +
		global_regular.neighbor + global_regular.plain);
	checksum = fold(checksum, global_packed.first + global_packed.straddling +
		global_packed.signed_value + global_packed.last + global_packed.neighbor +
		global_packed.trailer);

	return bad ? bad : checksum;
}
