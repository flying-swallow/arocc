// #kind: run
// #exit: 20
int main(void) { signed char c = -3; unsigned char u = 250; short s = -1000; int r = 0;
	if (c < 0) r += 1; if (u > 200) r += 2; if (s == -1000) r += 4; if ((int)(unsigned char)c == 253) r += 13; return r; }
