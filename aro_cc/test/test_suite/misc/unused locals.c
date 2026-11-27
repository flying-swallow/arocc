// #skip: diagnostics differ (aro_c3 gap)
// #opt: -Wunused -Wunused-parameter -Wno-implicit-int -Wno-deprecated-non-prototype
void unused_locals(int a_param, [[maybe_unused]] int b_param, int c_param) { // #warning@24: unused parameter 'a_param' [-Wunused-parameter]
    (void)c_param;

    typedef int A; // #warning@17: unused typedef 'A' [-Wunused-local-typedef]
    __attribute__((unused)) typedef int B;
    typedef int C;

    int a; // #warning@9: unused variable 'a' [-Wunused-variable]
    [[maybe_unused]] int b;
    int c;
    (void)c;

    a_label: ; // #warning@5: unused label 'a_label' [-Wunused-label]
    b_label: __attribute__((unused));
    c_label: ;
    goto c_label;
    goto d_label;
    d_label: ;

    C self = self;
}

void unused_kr_param(a, b, c) // #warning@28: unused parameter 'c' [-Wunused-parameter]
    int b; // #note@9: previous definition is here
    int b; // #error@9: redefinition of parameter 'b'
{
    (void)a;
    (void)b;
}


