// #kind: run
// #exit: 0

struct Pair { int left; int right; };

static int struct_local(int x)
{
	struct Pair pair;
	pair.left = x;
	pair.right = x + 3;
	pair.left += pair.right;
	return pair.left - pair.right;
}

static int array_local(int seed)
{
	int values[4];
	values[0] = seed;
	values[1] = seed + 1;
	values[2] = seed + 2;
	values[3] = seed + 3;
	values[1] += values[3];
	return values[0] + values[1] + values[2] + values[3];
}

int main(int argc, char **argv)
{
	int input = argc + 4;
	if (struct_local(input) != input) return 1;
	if (struct_local(-input) != -input) return 2;
	if (array_local(input) != 5 * input + 9) return 3;
	if (array_local(-input) != -5 * input + 9) return 4;
	return 0;
}
