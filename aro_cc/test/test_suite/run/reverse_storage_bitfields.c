// #kind: run
// #exit: 0
/* Reverse storage order must affect automatic and static initializers,
   signed reads, and read-modify-write operations. */
struct __attribute__((scalar_storage_order("big-endian"))) S {
  signed int i : 24;
  unsigned char a : 1;
  unsigned char b : 7;
};
static struct S g = { 0x123456, 1, 0x35 };
int main(void) {
  struct S s = { 0x123456, 1, 0x35 };
  unsigned char *p = (unsigned char *)&s;
  unsigned char *q = (unsigned char *)&g;
  if (p[0] != 0x12 || p[1] != 0x34 || p[2] != 0x56 || p[3] != 0xb5) return 1;
  for (int j = 0; j < 4; ++j) if (p[j] != q[j]) return 2;
  if (s.i != 0x123456 || s.a != 1 || s.b != 0x35) return 3;
  s.i = -2;
  s.b += 1;
  if (s.i != -2 || s.b != 0x36 || s.a != 1) return 4;
  if (p[0] != 255 || p[1] != 255 || p[2] != 254 || p[3] != 0xb6) return 5;
  return 0;
}
