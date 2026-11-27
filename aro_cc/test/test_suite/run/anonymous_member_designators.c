// #kind: run
// #exit: 0
// A designator may name a member of an anonymous struct/union member
// (c-testsuite 00216), and GNU allows casting a record value to its own type.
struct S { char x, y; };
union UV {
	struct { unsigned char a, b; };
	struct S s;
};
union UV g1 = { .b = 8, .a = 7 };
struct Outer {
	int head;
	union { struct { int p, q; }; long both; };
	int tail;
};
struct Outer g2 = { .q = 4, .tail = 5, .head = 1 };
int main(void)
{
	union UV l = { .b = 2 };
	struct Outer o = { .p = 3, 9 };
	struct S s = { 1, 2 };
	struct S t = (struct S)s;
	if (g1.a != 7 || g1.b != 8 || l.a != 0 || l.b != 2) return 1;
	if (g2.head != 1 || g2.p != 0 || g2.q != 4 || g2.tail != 5) return 2;
	if (o.p != 3 || o.q != 9) return 3;
	return t.x == 1 && t.y == 2 ? 0 : 4;
}
