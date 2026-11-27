// #opt: -Wno-unused
void foo(void) {
    1.0f == 1.0f;
    (double)1 + 1U == 2.0;
    (_Complex float)1 + 2U;
    1U + (int *)1;
    1U + &2; // #error@10: cannot take the address of an rvalue
}

