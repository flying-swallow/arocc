// #kind: run
// #exit: 33
int classify(int x) { switch (x) { case 1: return 10; case 2: case 3: return 20; default: return 3; } }
int main(void) { return classify(1) + classify(3) + classify(9); }
