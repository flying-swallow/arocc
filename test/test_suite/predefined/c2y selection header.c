// #skip: diagnostics differ (aro_c3 gap)
// #opt: -std=c2y -Wpre-c2y-compat
void entry() {
    if (int a = 1) { // #warning@9: declarations in if conditions are incompatible with C standards before C2y [-Wpre-c2y-compat]
        a -= 1;
    } else {
        a += 1;
    }
    #pragma GCC diagnostic ignored "-Wpre-c2y-compat"
    if (float a = 2.0; a != 0.0) { 
        a *= 3;
    }
    switch (int a = 3) { }
    switch (float a = 4.0, b = 5.0) { } // #error@13: declaration in condition can only declare a single objec
    if (int a[2] = {1, 2}) {} // #error@13: declaration in condition must have a scalar type ('int [2]' invalid)
    if (int a) {} // #error@13: variable declaration in condition must have an initializer
    if (typedef int a) {} // #error@21: declaration in condition must be a variable
    if (int x = 1, y = 2; x < y) { }
    if (int x = 1, y = 2 x < y) { } // #error@26: expected ';', found 'an identifier'
    if (int x = 1, y = 2;) { } // #error@26: expected expression
}

