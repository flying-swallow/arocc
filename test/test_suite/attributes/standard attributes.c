// #skip: diagnostics differ (aro_c3 gap)
// #opt: -std=c23
#pragma GCC diagnostic ignored "-Wgnu-alignof-expression"

#if __has_c_attribute(foo) || __has_c_attribute(foo::bar)
#error fail
#endif

#if !__has_c_attribute(deprecated) || !__has_c_attribute(gnu::__aligned__)
#error fail
#endif

void foo(void) {
    [[deprecated]] int x; // #note@7: 'x' has been explicitly marked deprecated here
    x = 5; // #warning@5: 'x' is deprecated [-Wdeprecated-declarations]
}

[[nodiscard]] int bar(void) {
    [[__gnu__::__aligned__(16)]] int x;
    _Static_assert(_Alignof(x) == 16, "incorrect alignment");
    return 5;
}

