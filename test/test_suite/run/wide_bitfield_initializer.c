// #kind: run
// #exit: 0
// Reduced from gcc.dg/pr89037.c: a constant initializer for a bit-field wider
// than 64 bits (incl. negative values) is serialized across limbs; it used to
// panic shifting a ulong by 64. Bytes are checked directly so the case does
// not depend on bit-field load lowering.
struct s { __int128 y : 66; };
struct s a[] = { -1, (__int128) 1 << 64, ((__int128) 1 << 64) | 1, -((__int128) 1 << 64) };
int main(void)
{
  unsigned char *p = (unsigned char *)a;
  /* -1: 66 one bits; bits 66..127 of the storage stay zero */
  for (int i = 0; i < 8; i++) if (p[i] != 0xff) return 1;
  if (p[8] != 0x03) return 2;
  if (p[16 + 8] != 0x01 || p[16] != 0) return 3;
  if (p[32] != 0x01 || p[32 + 8] != 0x01) return 4;
  /* -(1<<64): low 64 bits zero, bits 64,65 set */
  for (int i = 0; i < 8; i++) if (p[48 + i] != 0) return 5;
  if (p[48 + 8] != 0x03) return 6;
  return 0;
}
