// #opt: -std=c2y -Wpre-c2y-compat
static_assert(0o77 == 0'77); // #warning@15: octal integer literals are incompatible with C standards before C2y [-Wpre-c2y-compat] // #warning@23: octal literals without a '0o' prefix are deprecated [-Wdeprecated-octal-literals]

