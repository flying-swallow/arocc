// #skip: diagnostics differ (aro_c3 gap)
// #opt: -fno-ms-extensions
typedef struct {
    int a;
} unnamed;
typedef struct named {
    int b;
} named;

struct S {
    unnamed; // #warning@12: declaration does not declare anything [-Wmissing-declaration]
    named; // #warning@10: declaration does not declare anything [-Wmissing-declaration]
};

