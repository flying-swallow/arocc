// #kind: run
// #exit: 116
/* Struct/union member access through `.` and `->`: nested members, arrays in
   records, anonymous members, pointer chains, read-modify-write. */
struct In { int x; char c; };
struct S { char tag; long w; struct In in; int arr[3]; struct S *next; union { int i; unsigned u; } un; struct { short a, b; }; };
static int f(struct S *p) { return p->in.x + p->arr[2] + p->next->tag + p->un.i + p->b; }
int main(void)
{
	struct S a = { 1, 2, { 3, 4 }, { 5, 6, 7 }, 0, { 8 }, { 9, 10 } };
	struct S b = { .tag = 20, .next = &a };
	b.in.x = 30; b.arr[2] = 40; b.un.u = 2; b.b = 5;
	a.w += b.tag;                      /* 22 */
	b.next->in.c = 'z';
	int r = f(&b);                     /* 30 + 40 + 1 + 2 + 5 = 78 */
	struct S *pa = &a;
	r += pa->in.c == 'z';              /* 79 */
	r += (int)a.w + a.a;               /* 79 + 22 + 9 = 110 */
	pa->arr[0]++;
	r += a.arr[0];                     /* 116 */
	return r;
}
