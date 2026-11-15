enum E {
    A,
};

void foo(void) {
    int x;
    unsigned y;
    enum E *p1 = &x; // #warning@18: incompatible pointer types initializing 'enum E *' from incompatible type 'int *' [-Wincompatible-pointer-types]
    enum E *p2 = &y;
}

