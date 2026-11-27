// #opt: --emulate=clang
void foo(void) {
    __float80 x; // #error@5: use of undeclared identifier '__float80'
    double y = 1.0w; // #error@16: invalid suffix 'w' on floating constant
    _Complex double z = 2.0iw; // #error@25: invalid suffix 'iw' on floating constant
}

