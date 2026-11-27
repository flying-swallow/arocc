// #skip: diagnostics differ (aro_cc gap)
struct S {
  __attribute__((__aligned__(x(long)))) long a; // #error@30: call to undeclared function 'x'; ISO C99 and later do not support implicit function declarations [-Wimplicit-function-declaration] // #error@32: expected expression
  __attribute__((packed)) b; // #error@27: unknown type name 'b'
};

struct S2 {
  __attribute__((__aligned__(char:  1))) long a; // #error@30: expected expression
  __attribute__((packed)) b; // #error@27: unknown type name 'b'
};

void foo(void) {
}

