// #kind: run
// #exit: 15
int div(int a, int b) { return a / b; }
int rem(int a, int b) { return a % b; }
int main(void) { return (div(-7, 2) == -3) + (rem(-7, 2) == -1) * 2 + (div(7, -2) == -3) * 4 + (-8 >> 1 == -4) * 8; }
