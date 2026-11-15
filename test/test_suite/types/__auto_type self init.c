// #opt: -std=c23
void foo(void) {
    int x;
    __auto_type x = x; // #error@21: variable 'x' declared with deduced type '__auto_type' cannot appear in its own initializer
    
    __auto_type y = (int []){1, y}; // #error@33: variable 'y' declared with deduced type '__auto_type' cannot appear in its own initializer
    
    auto z = z + 1; // #error@14: variable 'z' declared with deduced type '__auto_type' cannot appear in its own initializer
}

