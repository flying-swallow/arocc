// #kind: run
// #exit: 0

static int same_product_sum(int p, int a, int b, int c)
{
	if (p) return a * b + c;
	return a * b + c;
}

static int select_sum(int p, int x, int y, int k)
{
	return p ? x + k : y + k;
}

int main(void)
{
	int failures = 0;
	for (int p = 0; p <= 1; ++p) {
		for (int a = -2; a <= 2; ++a) {
			for (int b = -2; b <= 2; ++b) {
				for (int c = -2; c <= 2; ++c) {
					if (same_product_sum(p, a, b, c) != a * b + c) failures |= 1;
				}
			}
		}
		for (int x = -2; x <= 2; ++x) {
			for (int y = -2; y <= 2; ++y) {
				for (int k = -2; k <= 2; ++k) {
					int expected = p ? x + k : y + k;
					if (select_sum(p, x, y, k) != expected) failures |= 2;
				}
			}
		}
	}
	return failures;
}
