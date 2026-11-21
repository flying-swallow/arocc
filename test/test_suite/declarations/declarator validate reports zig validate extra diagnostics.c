// #opt: -std=c17 -target x86_64-linux
struct S; struct S a[2]; // #error@21: array has incomplete element type 'struct S'
int f[2](void); // #error@6: arrays cannot have functions as their element type
int g(void)[2]; // #error@6: function cannot return an array
int h(void)(void); // #error@6: function cannot return a function
void p(int x[2][static 3]); // #error@13: 'static' used in non-outermost array type
char huge[0x7fffffffffffffff][16]; // #error@10: array is too large
int ok[2][3];
