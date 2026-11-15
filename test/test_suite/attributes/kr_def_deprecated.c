// #opt: -std=c23
int foo(a, int b, char c, d) // #error@9: unknown type name 'a' // #error@27: unknown type name 'd' // #error@28: expected function body after function declaration
    int a; short d;
{ // #error@1: expected external declaration
    return a;
}

int baz() {
    return bar(1); // #error@12: use of undeclared identifier 'bar'
    // TODO no return-type warning
} // #warning@1: non-void function 'baz' does not return a value [-Wreturn-type]

