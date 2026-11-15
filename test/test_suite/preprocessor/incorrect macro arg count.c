// #kind: expand_error
#define TWO_ARGS(A, B) A B

TWO_ARGS() // #error@1: expected 2 argument(s) got 1
TWO_ARGS(A) // #error@1: expected 2 argument(s) got 1
TWO_ARGS(A, B, C) // #error@1: expected 2 argument(s) got 3
TWO_ARGS(,,,) // #error@1: expected 2 argument(s) got 4

