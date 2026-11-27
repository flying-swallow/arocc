// #kind: expand_error
#define h(x) x(0) // #note@14: expanded from here
#define s()
h(s) // #error@1: expected 0 argument(s) got 1 // #note@3: expanded from here

