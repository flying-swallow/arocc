// #kind: run
// #exit: 9
int abs(int);
int main(void) { int (*f)(int) = abs; return f(-9); }
