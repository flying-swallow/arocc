// #skip: diagnostics differ (aro_c3 gap)
// #opt: -Wzero-length-array
struct S {
    int x;
    int y[0]; // #warning@10: zero size arrays are an extension [-Wzero-length-array]
};

void foo(void) {
    struct S s;
    s.y[2] = 5;
    int z[0]; // #warning@10: zero size arrays are an extension [-Wzero-length-array]
    z[5] = 2;
}

