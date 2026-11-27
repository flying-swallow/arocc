// #kind: run
// #exit: 0
// Structs with bit-fields passed and returned by value (gcc compat
// struct-layout-1, csmith): their IR record type is a byte array, like unions.
struct B { unsigned a : 3; int b : 5; long c : 40; char d; };
static struct B make(int x) { struct B r = { x, -x, (long)x << 20, 'q' }; return r; }
static long sum(struct B v) { return v.a + v.b + v.c + v.d; }
struct Small { unsigned x : 4, y : 4; };
static struct Small swap(struct Small s) { struct Small t = { s.y, s.x }; return t; }
int main(void)
{
  struct B b = make(5);
  if (b.a != 5 || b.b != -5 || b.c != (5L << 20) || b.d != 'q') return 1;
  if (sum(b) != 5 - 5 + (5L << 20) + 'q') return 2;
  struct Small s = swap((struct Small){ 1, 2 });
  if (s.x != 2 || s.y != 1) return 3;
  return 0;
}
