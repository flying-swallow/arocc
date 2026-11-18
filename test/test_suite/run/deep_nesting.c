// #kind: run
// #exit: 0
// Deep nesting must fit the 64 MiB stack aro_c3 requests at startup (like
// GCC's stack_limit_increase): 3000-4000 levels need a few KiB per level in
// the parser and codegen. Frames of ~10-25 KiB per level used to overflow.
// Repetition is additive (3000 = 1000 x 3), never nested macro calls.
#define L10 ( ( ( ( ( ( ( ( ( (
#define L100 L10 L10 L10 L10 L10 L10 L10 L10 L10 L10
#define L1000 L100 L100 L100 L100 L100 L100 L100 L100 L100 L100
#define R10 ) ) ) ) ) ) ) ) ) )
#define R100 R10 R10 R10 R10 R10 R10 R10 R10 R10 R10
#define R1000 R100 R100 R100 R100 R100 R100 R100 R100 R100 R100
#define T10(x) x x x x x x x x x x
#define T100(x) T10(x) T10(x) T10(x) T10(x) T10(x) T10(x) T10(x) T10(x) T10(x) T10(x)
#define T1000(x) T100(x) T100(x) T100(x) T100(x) T100(x) T100(x) T100(x) T100(x) T100(x) T100(x)

// 3000 nested parentheses.
int parens(int x) { return L1000 L1000 L1000 x R1000 R1000 R1000; }

// 4000 nested blocks.
int blocks(int x) { T1000({) T1000({) T1000({) T1000({) x++; T1000(}) T1000(}) T1000(}) T1000(}) return x; }

// A 4000-arm else-if chain.
int chain(int x)
{
    if (x == -1) return 1;
    T1000(else if (x == -1) return 1;) T1000(else if (x == -1) return 1;)
    T1000(else if (x == -1) return 1;) T1000(else if (x == -1) return 1;)
    return x;
}

// 3000 nested anonymous struct members.
struct { T1000(struct {) T1000(struct {) T1000(struct {) int v; T1000(} m;) T1000(} m;) T1000(} m;) } deep;

int main(void)
{
    if (parens(3) != 3) return 1;
    if (blocks(4) != 5) return 2;
    if (chain(5) != 5) return 3;
    return 0;
}
