// #skip: diagnostics differ (aro_c3 gap)
int b;

struct Foo {
   float a: 1; // #error@10: bit-field has non-integer type 'float'
   int c: b, d: -1; // #error@11: expression is not an integer constant expression // #error@14: bit-field has negative width (-1)
   int e: 64, f:0; // #error@8: width of bit-field exceeds width of its type // #error@15: named bit-field has zero width
};

