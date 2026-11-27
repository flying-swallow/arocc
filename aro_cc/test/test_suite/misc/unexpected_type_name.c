typedef int foo;
void bar(void) {
    int a = foo; // #error@13: unexpected type name 'foo': expected expression
}

