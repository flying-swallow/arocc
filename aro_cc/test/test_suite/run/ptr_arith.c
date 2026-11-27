// #kind: run
// #exit: 0
void *malloc(unsigned long);
int main(void) {
    int *p = malloc(40);
    for (int i = 0; i < 10; i++) *(p + i) = i;
    int *e = p + 9;
    if (*(e - 2) != 7) return 1;
    int *q = p + 5;
    if (q - p != 5) return 2;
    if (*(p + 5 - 2) != 3) return 3;
    return 0;
}
