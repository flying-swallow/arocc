// #skip: diagnostics differ (aro_c3 gap)
// #opt: -Wno-unused-value
void foo(void) {
    _Generic(0); // #error@15: expected ',', found ')'
    _Generic(1,); // #error@16: expected a type
    _Generic(2, const int: 3); // #warning@17: generic association with qualifiers cannot be matched with [-Wgeneric-qual-type]
    _Generic(4, default: 5, default: 6); // #error@29: duplicate default generic association // #note@17: previous case defined here
    (void)_Generic(7, double: 8, double: 9); // #error@34: type 'double' in generic association compatible with previously specified type // #note@23: compatible type 'double' specified here // #error@20: controlling expression type 'int' not compatible with any generic association type
    (void)_Generic(7, int: 8, int: 9); // #error@31: type 'int' in generic association compatible with previously specified type // #note@23: compatible type 'int' specified here
    _Static_assert(_Generic(7, int[2]: 8, int(int): 9, default: 1) == 1, "test failure"); // #warning@32: generic association array type cannot be matched with [-Wgeneric-qual-type] // #warning@43: generic association function type cannot be matched with [-Wgeneric-qual-type]
    _Static_assert(_Generic(7, default: 1) == 1, "test failure");
    _Static_assert(_Generic("hello", char *: 1, default: 2) == 1, "test failure");
    _Generic(0, int: 8, long: bar()); // #error@31: call to undeclared function 'bar'; ISO C99 and later do not support implicit function declarations [-Wimplicit-function-declaration]
}

