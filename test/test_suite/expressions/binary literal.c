// #opt: -Wpedantic -std=c17 -Wno-unused-value
void foo(void) {
  0b11; // #warning@3: binary integer literals are a C23 extension [-Wc23-extensions]
}

