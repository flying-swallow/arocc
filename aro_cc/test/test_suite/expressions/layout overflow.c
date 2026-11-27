// #skip: diagnostics differ (aro_cc gap)
// #opt: -fdeclspec
struct S { // #error@8: type 'struct S' is too large
    char x[2305843009213693952ULL -1];
    char y[2305843009213693952ULL -1];
};


struct __declspec(align(268435456)) S1 {
    char one;
    char two[2];
    char eight[8];
    char four[4];
};

struct S2 {
    __attribute__((aligned(268435456))) int x;
};

union U {
    int a;
    char bytes[3333333333333333333]; // #error@15: array is too large
};

