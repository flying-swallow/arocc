// #opt: -std=c89
void baz(void) {
    int x<:5:>; // #error@10: expected ';', found '<'
}

