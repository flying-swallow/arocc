// #skip: diagnostics differ (aro_c3 gap)
long float a; // #error@6: cannot combine with previous 'long' specifier

enum Foo {}; // #error@11: empty enum is invalid

typename foo; // #error@1: unknown type name 'typename'

void f[4]; // #error@7: array has incomplete element type 'void'
struct Bar f; // #error@12: tentative definition has type 'struct Bar' that is never completed // #note@8: forward declaration of 'struct Bar'
int x[2305843009213693951u]; // #error@6: array is too large

_Complex z; // #warning@1: plain '_Complex' requires a type specifier; assuming '_Complex double'


void foo(int arr[]) { // #note@6: previous definition is here
    typeof(arr) a[2];
    struct bar[1] = {1}; // #error@15: expected identifier or '('
    struct bar a[] = {1}; // #error@17: array has incomplete element type 'struct bar'
    struct bar[1][1] = {{1}}; // #error@15: expected identifier or '('
    struct bar b[1][] = {{1}}; // #error@17: array has incomplete element type 'struct bar'
    struct bar b[1][B(1)] = {1}; // #error@21: call to undeclared function 'B'; ISO C99 and later do not support implicit function declarations [-Wimplicit-function-declaration] // #warning@23: passing arguments to a function without a prototype is deprecated in all versions of C and is not supported in C23 [-Wdeprecated-non-prototype] // #error@17: array has incomplete element type 'struct bar'
}

int bar["foo"]; // #error@9: size of array has non-integer type 'char [4]'
int baz[] = 111111E1111111111111; // #error@13: array initializer must be an initializer list or wide string literal
int qux[] = baz; // #error@13: array initializer must be an initializer list or wide string literal

int g[]; // #warning@5: tentative array definition assumed to have one element
extern int h[];
void foo(void) { // #error@6: redefinition of 'foo'
    int i[]; // #error@9: variable has incomplete type 'int []'
    char j[] = "hello";
}

typedef struct Incomplete ArrayOfIncomplete[]; // #error@44: array has incomplete element type 'struct Incomplete'
ArrayOfIncomplete a;

