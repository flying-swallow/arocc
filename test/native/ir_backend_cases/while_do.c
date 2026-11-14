// expect 21
int main(void) { int n = 0, i = 0; while (i < 6) { n += i; i++; } do { n += 6; } while (0); return n; }
