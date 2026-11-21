// #kind: run
// #exit: 0
// C symbols spelled like Intel-syntax operators, size keywords or registers
// must be quoted in assembly text for GNU as (-fno-integrated-as).
static char byte = 3;
int shl = 4;
static int *ptr = &shl;
long rax(void) { return byte + *ptr; }
static int not(int x) { return !x; }

int main(void) { return rax() == 7 && not(0) ? 0 : 1; }
