int a = __builtin_offsetof(int, a); // #error@28: offsetof requires struct or union type, 'int' invalid
struct A;
int b = __builtin_offsetof(struct A, a); // #error@28: offsetof of incomplete type 'struct A'
struct A{
    int *a;
};
int b = __builtin_offsetof(struct A, b); // #error@38: no member named 'b' in 'struct A'
int b = __builtin_offsetof(struct A, a[1]); // #error@39: offsetof requires array type, 'int *' invalid

struct Foo {
  char a;
} __attribute__((packed));
_Static_assert(__builtin_offsetof(struct Foo, a) == 0, "field Foo.a wrong bit offset");
_Static_assert(__builtin_bitoffsetof(struct Foo, a) == 0, "field Foo.a wrong bit offset");

struct B {
    int a[4];
};
void foo(void) {
    int a = 2;
    _Static_assert(__builtin_offsetof(struct B, a[a]) == 8ul, ""); // #error@20: static assertion expression is not an integral constant expression
}
_Static_assert(__builtin_offsetof(struct B, a[2]) == 8ul, "");

struct Anon {
    union {
        int x;
        struct {
            int s1, s2;
        };
        struct {
            int s3, s4;
        } s;
    };
};
_Static_assert(__builtin_offsetof(struct Anon, x) == __builtin_offsetof(struct Anon, s1), "");
_Static_assert(__builtin_offsetof(struct Anon, s2) > __builtin_offsetof(struct Anon, s.s3), "");
_Static_assert(__builtin_offsetof(struct Anon, s.s4) > __builtin_offsetof(struct Anon, s1), "");

