// #opt: -std=c23
#define TWO_PRAGMAS_IN_ONE \
  _Pragma("GCC diagnostic push") \
  _Pragma("GCC diagnostic ignored \"-Wdeprecated-declarations\"")

TWO_PRAGMAS_IN_ONE
void foo(void) {
  [[deprecated]] int x;
  x = 5;
}

#pragma GCC diagnostic pop
void bar(void) {
  [[deprecated]] int x; // #note@5: 'x' has been explicitly marked deprecated here
  x = 5; // #warning@3: 'x' is deprecated [-Wdeprecated-declarations]
}


