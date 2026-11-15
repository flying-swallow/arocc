// #kind: run
// #exit: 15
unsigned udiv(unsigned a, unsigned b) { return a / b; }
int main(void) {
	unsigned big = 4000000000u;
	int ok = 0;
	if (big > 1u) ok += 1;
	if (udiv(big, 2u) == 2000000000u) ok += 2;
	if ((big >> 31) == 1u) ok += 4;
	if (big % 7u == 4000000000u % 7u) ok += 8;
	return ok;
}
