// #kind: run
// #exit: 12
void set(int *p, int v) { *p = v; }
int main(void) { int a = 1; int b = 2; int *p = &a; set(p, 5); set(&b, 7); return a + b; }
