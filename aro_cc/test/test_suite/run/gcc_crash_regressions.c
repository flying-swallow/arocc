// #kind: run
// #exit: 0
// Reduced from GCC torture cases that used to crash aro_cc (zero-struct-1.c,
// 961125-1.c, strcmpopt_6.c) plus folded `||`/`&&` codegen.
char y[3];
char *f = &y[0];

char *advance(char *ptr, int n) { ptr += n; ptr -= 1; return ptr; }

int or_zero(int x) { return 0 || x; }
int and_one(int x) { return 1 && x; }
int or_one(int x) { return 1 || x; }
int and_zero(int x) { return 0 && x; }

int hits;
void hit(void) { hits++; }
void check(int ok) { ok ? (void)0 : (hit(), (void)0); }

int main(void)
{
    f++;
    if (f != &y[1]) return 1;          // non-constant pointer compared to an address constant
    if (advance(y, 3) != &y[2]) return 2;
    if (or_zero(0) != 0 || or_zero(5) != 1) return 3;
    if (and_one(0) != 0 || and_one(5) != 1) return 4;
    if (or_one(0) != 1 || and_zero(5) != 0) return 5;
    check(1);
    check(0);
    if (hits != 1) return 6;           // void conditional with a (void)0 arm
    return 0;
}
