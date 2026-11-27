// #kind: run
// #exit: 0
// Unnamed bit-fields are not members: positional initializers skip them
// (csmith seed 27: `signed : 0;` took the second value).
struct A { int a; int : 3; int b; int : 0; int c; };
struct A x = { 1, 2, 3 };
struct B { struct A in; int d; } y = { {4, 5, 6}, 7 };
struct B z = { 8, 9, 10, 11 };
int main(void){ return !(x.a==1&&x.b==2&&x.c==3&&y.in.c==6&&y.d==7&&z.in.a==8&&z.in.c==10&&z.d==11); }
