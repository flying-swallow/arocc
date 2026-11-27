// #kind: run
// #exit: 0
#include <stdint.h>
#include <string.h>

static int diamond(int a, int b, int choose) {
	int before = a + b;
	int value;
	if (choose && before > 0) value = a + b;
	else value = b + a;
	return value;
}

static int parallel_inductions(int limit) {
	int i = 0;
	int j = 0;
	int sum = 0;
	while (i < limit) {
		i++;
		j++;
		sum += i + j;
	}
	return i == j ? sum : -1;
}

static int array_load_across_loop(int seed, int index, int rounds) {
	int values[4] = { seed, seed + 1, seed + 2, seed + 3 };
	values[index] = seed + 17;
	int initial = values[0];
	int sum = initial;
	for (int i = 0; i < rounds; ++i) sum += values[0];
	return sum;
}

static int join_store_load(int seed, int index, int choose) {
	int values[4] = { seed, seed + 1, seed + 2, seed + 3 };
	if (choose) values[index] = seed + 9;
	return values[0];
}

static uint64_t double_bits(double value) {
	uint64_t bits;
	memcpy(&bits, &value, sizeof bits);
	return bits;
}

static int float_operand_order(int salt) {
	uint64_t left_bits = UINT64_C(0x7ff8000000000011) + (uint64_t)(salt & 7);
	uint64_t right_bits = UINT64_C(0x7ff8000000000022) + (uint64_t)(salt & 7);
	double left, right;
	memcpy(&left, &left_bits, sizeof left);
	memcpy(&right, &right_bits, sizeof right);
	volatile double left_right = left + right;
	volatile double right_left = right + left;
	return double_bits(left_right) != double_bits(right_left);
}

int main(int argc, char **argv) {
	(void)argv;
	int a = argc * 7 + 3;
	int b = argc * 11 + 5;
	int rounds = argc % 5 + 1;
	int index = argc % 4;
	int expected_array = (index == 0 ? a + 17 : a) * (rounds + 1);
	if (diamond(a, b, argc & 1) != a + b) return 1;
	if (parallel_inductions(rounds) != rounds * (rounds + 1)) return 2;
	if (array_load_across_loop(a, index, rounds) != expected_array) return 3;
	if (join_store_load(a, index, argc & 1) != ((index == 0 && (argc & 1)) ? a + 9 : a)) return 4;
	if (!float_operand_order(argc)) return 5;
	return 0;
}
