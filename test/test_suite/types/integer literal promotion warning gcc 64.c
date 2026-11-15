// #opt: --emulate=gcc --target=x86_64-linux-gnu
_Static_assert(__builtin_types_compatible_p(typeof(18446744073709550592), __int128), ""); // #warning@52: integer literal is too large to be represented in a signed integer type, interpreting as unsigned [-Wimplicitly-unsigned-literal]

