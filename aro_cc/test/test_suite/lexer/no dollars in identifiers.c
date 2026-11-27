// #opt: -fno-dollars-in-identifiers
#define foo$ bar // #warning@12: ISO C99 requires whitespace after the macro name [-Wc99-extensions] // #note@12: expanded from here
void fib() {
  int foo$; // #error@7: expected identifier or '('
}

