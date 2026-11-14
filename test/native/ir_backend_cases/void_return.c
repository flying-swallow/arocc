// expect 4
void bump(int *p) { if (*p > 100) return; *p = *p + 4; }
int main(void) { int v = 0; bump(&v); return v; }
