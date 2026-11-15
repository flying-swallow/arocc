// #skip: diagnostics differ (aro_c3 gap)
// #opt: -fms-extensions
typedef struct {
    int a;
} unnamed;
typedef struct named {
    int b;
} named;

struct S {
    unnamed; // #warning@12: anonymous structs are a Microsoft extension [-Wmicrosoft-anon-tag]
    named; // #warning@10: anonymous structs are a Microsoft extension [-Wmicrosoft-anon-tag]
};

