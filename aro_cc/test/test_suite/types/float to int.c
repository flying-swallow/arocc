#pragma GCC diagnostic warning "-Wliteral-conversion"
#pragma GCC diagnostic warning "-Wfloat-conversion"
#pragma GCC diagnostic warning "-Wfloat-overflow-conversion"
#pragma GCC diagnostic warning "-Wfloat-zero-conversion"

void foo(void) {
    int a = 10000000000.0f; // #warning@13: implicit conversion of out of range value from 'float' to 'int' is undefined [-Wliteral-conversion]
    int b = 1.2f; // #warning@13: implicit conversion from 'float' to 'int' changes value from 1.2 to 1 [-Wfloat-conversion]
    int c = 0.0f / 0; // #warning@13: implicit conversion of non-finite value from 'float' to 'int' is undefined [-Wfloat-overflow-conversion]
    int d = 5.0 / 2; // #warning@13: implicit conversion from 'double' to 'int' changes value from 2.5 to 2 [-Wfloat-conversion]
    int e = 1.0f / 2; // #warning@13: implicit conversion from 'float' to 'int' changes non-zero value from 0.5 to 0 [-Wfloat-zero-conversion]
    int f = 2.0; // #warning@13: implicit conversion turns floating-point number into integer: 'double' to 'int' [-Wliteral-conversion]
    int g = 2147483647.0f; // #warning@13: implicit conversion of out of range value from 'float' to 'int' is undefined [-Wliteral-conversion]
    char h = 256.0f; // #warning@14: implicit conversion of out of range value from 'float' to 'char' is undefined [-Wliteral-conversion]
    unsigned i = -1.0; // #warning@18: implicit conversion of out of range value from 'double' to 'unsigned int' is undefined [-Wliteral-conversion]
    _Bool j = 0.0; // #warning@15: implicit conversion turns floating-point number into integer: 'double' to '_Bool' [-Wliteral-conversion]
    _Bool k = 1.0f; // #warning@15: implicit conversion turns floating-point number into integer: 'float' to '_Bool' [-Wliteral-conversion]
    _Bool l = 1.5f; // #warning@15: implicit conversion from 'float' to '_Bool' changes value from 1.5 to true [-Wfloat-conversion]
}

