// expect 42
int add1(int x) { return x + 1; }
int main(void) { int (*f)(int) = add1; return f(41); }
