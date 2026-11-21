// #opt: -std=c17 -target x86_64-linux -Wignored-qualifiers
typedef struct S5 { char c[3]; } T5 __attribute__((aligned(4))); T5 arr[2]; // #error@72: size of array element of type 'T5' (aka 'struct S5') (3 bytes) isn't a multiple of its alignment (4 bytes)
const int f(void); // #warning@12: 'const' type qualifier on return type has no effect
