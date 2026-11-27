// #kind: run
// #exit: 0

struct Pair { unsigned long long first, second; };

static inline int update_copy(struct Pair pair, int amount)
{
	pair.first += amount;
	pair.second -= amount;
	return (int)(pair.first + pair.second);
}

struct Large { unsigned long long words[5]; };

/* A 40-byte argument is passed in memory. Mutating this copy must not change
   the caller's object. */
static inline unsigned long long mutate_large_copy(struct Large value, unsigned long long amount)
{
	value.words[0] += amount;
	value.words[4] -= amount;
	return value.words[0] * value.words[4];
}

/* The 40-byte result uses the target's memory return convention. Keep this
   out of line while checking both sret return paths. */
static struct Large make_large(int alternate)
{
	struct Large result;
	if (alternate) {
		result.words[0] = 10;
		result.words[1] = 20;
		result.words[2] = 30;
		result.words[3] = 40;
		result.words[4] = 50;
		return result;
	}
	result.words[0] = 1;
	result.words[1] = 2;
	result.words[2] = 3;
	result.words[3] = 4;
	result.words[4] = 5;
	return result;
}

int main(void)
{
	struct Pair original = { 17, 29 };
	int result = update_copy(original, 4);
	struct Large argument = { { 3, 6, 9, 12, 15 } };
	unsigned long long copied_result = mutate_large_copy(argument, 4);
	struct Large first = make_large(0);
	struct Large second = make_large(1);
	return result == 46 && original.first == 17 && original.second == 29 &&
		copied_result == 77 && argument.words[0] == 3 && argument.words[4] == 15 &&
		first.words[0] == 1 && first.words[4] == 5 &&
		second.words[0] == 10 && second.words[4] == 50 ? 0 : 1;
}
