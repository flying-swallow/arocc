// Source-derived from test/cases/offsetof.c. Keep the assertions that exercise
// byte and bit offsets and an array designator without unrelated failures.
/** manifest:
syntax
args = --target=x86_64-linux-gnu
*/
struct Foo {
	char a;
} __attribute__((packed));

_Static_assert(__builtin_offsetof(struct Foo, a) == 0, "field Foo.a byte offset");
_Static_assert(__builtin_bitoffsetof(struct Foo, a) == 0, "field Foo.a bit offset");

struct B {
	int a[4];
};

_Static_assert(__builtin_offsetof(struct B, a[2]) == 8ul, "field B.a[2] byte offset");
