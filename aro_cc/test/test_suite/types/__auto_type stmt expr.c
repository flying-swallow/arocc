// Each deduced-type declaration owns its binding: a nested statement
// expression may declare and use its own __auto_type variable, while the
// outer variable stays unusable inside its own initializer.
void foo(void) {
    __auto_type a = ({ __auto_type b = 1; b; });
    __auto_type c = ({ c; }); // #error@24: variable 'c' declared with deduced type '__auto_type' cannot appear in its own initializer
    __auto_type d = ({ __auto_type e = 1; e + d; }); // #error@47: variable 'd' declared with deduced type '__auto_type' cannot appear in its own initializer
}
