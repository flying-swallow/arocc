// #skip: diagnostics differ (aro_c3 gap)
// #opt: --target=x86_64-macos
__float128 q = 0.0; // #error@1: __float128 is not supported on this target

