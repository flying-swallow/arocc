// #opt: -Wgnu-pointer-arith -Wno-unused-value
void foo(void *a, void *b) {
    b - a; // #warning@7: arithmetic on pointers to void is a GNU extension [-Wgnu-pointer-arith]
    a - 1; // #warning@7: arithmetic on pointers to void is a GNU extension [-Wgnu-pointer-arith]
    a + 1; // #warning@7: arithmetic on pointers to void is a GNU extension [-Wgnu-pointer-arith]
    ++a; // #warning@5: arithmetic on pointers to void is a GNU extension [-Wgnu-pointer-arith]
    --a; // #warning@5: arithmetic on pointers to void is a GNU extension [-Wgnu-pointer-arith]
    b++; // #warning@6: arithmetic on pointers to void is a GNU extension [-Wgnu-pointer-arith]
    b--; // #warning@6: arithmetic on pointers to void is a GNU extension [-Wgnu-pointer-arith]
}

