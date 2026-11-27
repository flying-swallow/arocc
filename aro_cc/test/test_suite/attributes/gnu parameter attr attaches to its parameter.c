// #opt: -target x86_64-linux -Wunused-parameter
// Prototype parameters are not dumped, so attachment is observed on a definition:
// `unused` silences -Wunused-parameter for p only.
int h(int __attribute__((unused)) p, int q);
int h(int __attribute__((unused)) p, int q) { return 0; } // #warning@42: unused parameter 'q'
