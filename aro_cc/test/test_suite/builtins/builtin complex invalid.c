void test(void *p, _Complex double z) {
    __builtin_complex(p, p); // #error@23: argument type 'void *' is not a real floating point type // #error@26: argument type 'void *' is not a real floating point type
    __builtin_complex(z, z); // #error@23: argument type '_Complex double' is not a real floating point type // #error@26: argument type '_Complex double' is not a real floating point type
}

