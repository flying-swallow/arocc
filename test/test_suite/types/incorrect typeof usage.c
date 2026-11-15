// #skip: diagnostics differ (aro_c3 gap)
void foo(void) {
    unsigned typeof(int) x; // #error@5: 'unsigned typeof' is invalid
    typeof(int) typeof(int) y; // #error@5: cannot combine with previous 'typeof' specifier
    typeof() z; // #error@12: expected expression
    typeof(int) unsigned w; // #error@17: 'unsigned typeof' is invalid
}

