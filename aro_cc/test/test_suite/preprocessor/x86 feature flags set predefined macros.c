// #kind: syntax
// #opt: --target=x86_64-linux-gnu -mno-mmx -msse4.1
// gcc/clang `-m<feature>` / `-mno-<feature>` toggle the CPU feature macros.
#ifdef __MMX__
#error "-mno-mmx left __MMX__ defined"
#endif
#if !defined(__SSE4_1__) || !defined(__SSSE3__) || !defined(__SSE2__)
#error "-msse4.1 did not enable SSE4.1 and the features it implies"
#endif
int ok;
