// #skip: diagnostics differ (aro_c3 gap)
void foo(void) {
    char arr[10];
    typeof(const int) *p = arr; // #warning@28: incompatible pointer types initializing 'typeof(const int) *' (aka 'const int *') from incompatible type 'char [10]' [-Wincompatible-pointer-types]
}

