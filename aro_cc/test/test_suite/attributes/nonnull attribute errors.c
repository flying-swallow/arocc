void bad_index_low(int *a) __attribute__((nonnull(0))); // #error@51: 'nonnull' attribute parameter 1 is out of bounds
void bad_index_high(int *a) __attribute__((nonnull(2))); // #error@52: 'nonnull' attribute parameter 1 is out of bounds
void bad_type(int *a, int b) __attribute__((nonnull(2))); // #warning@53: 'nonnull' attribute only applies to pointer arguments [-Wignored-attributes]

