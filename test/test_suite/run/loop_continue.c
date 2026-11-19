// #kind: run
// #exit: 80
/* `continue` in for loops must reach the increment (for.cont block; Zig
   CodeGen made the label but never started it, so `jmp` had no target). */
int main(void)
{
	int a = 0, b = 0, c = 0, d = 0;
	for (int i = 0; i < 10; i++) { if (i & 1) continue; a += i; }          /* 20 */
	int j = 0;
	for (;; j++) { if (j >= 10) break; if (j % 3) continue; b += j; }       /* 18 */
	for (int k = 0; k < 4; k++) for (int m = 0; m < 4; m++) { if (m == k) continue; c++; } /* 12 */
	int w = 0;
	while (w < 10) { w++; if (w & 1) continue; d += w; }                    /* 30 */
	do { w--; if (w > 5) continue; } while (w > 0);
	return a + b + c + d + w; /* 80 */
}
