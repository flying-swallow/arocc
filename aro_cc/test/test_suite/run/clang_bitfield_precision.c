// #kind: run
// #exit: 0
// #opt: --emulate=clang
struct S { unsigned long long a:33; };
struct S x = { 0x100000000ULL };
int main(void) { return x.a + x.a != 0x200000000ULL; }
