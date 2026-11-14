// expect 31
int t(int x) { return x; }
int main(void) {
	int r = 0;
	if (t(1) && t(2)) r += 1;
	if (t(0) || t(3)) r += 2;
	if (!t(0)) r += 4;
	r += t(5) > 3 ? 8 : 100;
	if (!(t(1) && t(0))) r += 16;
	return r;
}
