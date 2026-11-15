// #opt: -fno-digraphs
void baz(void) {
    int x<:5:>; // #error@10: expected ';', found '<'
}

