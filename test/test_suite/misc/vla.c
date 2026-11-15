// #skip: diagnostics differ (aro_c3 gap)
// #opt: -Wvla
void foo(int x) {
    int arr[x]; // #warning@13: variable length array used [-Wvla]
}

struct S {
    int x;
    int y[x]; // #error@11: use of undeclared identifier 'x'
};

void bar(int x) {
    int arr[2][3][x]; // #warning@19: variable length array used [-Wvla]
}

