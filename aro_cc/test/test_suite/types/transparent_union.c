// #skip: diagnostics differ (aro_c3 gap)
struct S1{
    int a;
    double b;
} __attribute__((transparent_union)); // #warning@18: 'transparent_union' attribute only applies to unions [-Wignored-attributes]
union U1 {
} __attribute__((transparent_union)); // #warning@18: transparent union definition must contain at least one field; 'transparent_union' attribute ignored [-Wignored-attributes]
union U2 {
    int a; // #note@9: size of first field is 32
    double b; // #warning@12: size of field 'b' (64 bits) does not match the size of the first field in transparent union; 'transparent_union' attribute ignored [-Wignored-attributes]
} __attribute__((transparent_union));
union U3 {
    int a;
    float b;
} __attribute__((transparent_union));

void f1(union U3);
void f2(void) {
    f1(1);
}

union U4 {
    int *a;
    float *b;
} __attribute__((transparent_union));
void f3(union U4); // #note@9: passing argument to parameter here
void f4(void) {
    f3(1); // #error@8: passing 'int' to parameter of incompatible type 'union U4'
    f3(0);
}

