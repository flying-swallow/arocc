// #kind: run
// #exit: 0
/* Exercise constant value propagation across integer, pointer, float, and
   loop comparisons. Each category has a distinct failure bit. */
int main(void)
{
	int failures = 0;
	int value = 37;

	if (!(value == 37) || !(value != 38)) failures |= 1;
	if (value != 37 || value == 38) failures |= 2;

	int object = 0;
	int *present = &object;
	int *missing = 0;
	if (present == 0 || missing != 0) failures |= 4;
	if (!(present != 0) || !(missing == 0)) failures |= 8;

	volatile double negative_zero = -0.0;
	volatile double positive_zero = 0.0;
	if (negative_zero != positive_zero) failures |= 16;
	if (!(negative_zero == positive_zero)) failures |= 32;

	int i = 0;
	int visited_last = 0;
	while (i != 6) {
		if (i == 5) visited_last = 1;
		++i;
	}
	if (!visited_last || i != 6) failures |= 64;

	int j = 0;
	int visits = 0;
	for (; j != 4; ++j) {
		if (j == 4) failures |= 128;
		++visits;
	}
	if (visits != 4 || j != 4) failures |= 256;

	return failures;
}
