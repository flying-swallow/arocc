typedef float *invalid1 __attribute__((vector_size(8))); // #error@40: invalid vector element type 'float *'
typedef float invalid1;

