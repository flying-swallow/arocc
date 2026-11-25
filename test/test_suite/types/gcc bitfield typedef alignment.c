// #kind: syntax
// #opt: --emulate=gcc --target=x86_64-linux-gnu
// GCC layout of bit-fields whose typedef changes the type's alignment: a
// narrower-than-type field aligns to the typedef's alignment; a full-width one
// stays at its naturally aligned position; the record still inherits both.
typedef char T16 __attribute__((aligned(16)));
typedef _Bool B8 __attribute__((aligned(8)));
typedef unsigned U8 __attribute__((aligned(8)));
typedef unsigned U2 __attribute__((aligned(2)));
enum E { e0, e_big = 4294967295U };
typedef enum E E2 __attribute__((aligned(2)));
enum F { f0 } __attribute__((aligned(16)));
struct S1 { unsigned a; T16 b:8; T16 c:1; long long g; };
struct S2 { B8 a:1; B8 b:1; B8 c:1; };
struct S3 { int a; U8 b:32; long long c; };
struct A { char x; T16 b:8; };
struct B { int a:3; T16 b:8; };
struct G { int a; U8 b:4; U8 c:4; };
struct K { E2 a:32; char g; };
struct M { U2 a:7; char g; };
_Static_assert(sizeof(struct S1) == 32 && _Alignof(struct S1) == 16, "S1");
_Static_assert(sizeof(struct S2) == 24, "S2");
_Static_assert(sizeof(struct S3) == 16, "S3");
_Static_assert(sizeof(struct A) == 16, "A");
_Static_assert(sizeof(struct B) == 32, "B");
_Static_assert(sizeof(struct G) == 24, "G");
_Static_assert(sizeof(struct K) == 8 && _Alignof(struct K) == 4, "K");
_Static_assert(sizeof(struct M) == 2 && _Alignof(struct M) == 2, "M");
_Static_assert(_Alignof(E2) == 2, "aligned typedef of an enum");
_Static_assert(_Alignof(enum F) == 4, "aligned on the enum itself is ignored");
// `aligned` after a `*` applies to the pointer type and may lower it; `packed`
// there does nothing.
struct PA { char b; int * __attribute__((aligned(2))) c; };
struct PB { char b; char * __attribute__((packed)) c; };
_Static_assert(__builtin_offsetof(struct PA, c) == 2 && sizeof(struct PA) == 10, "aligned pointer member");
_Static_assert(__builtin_offsetof(struct PB, c) == 8 && sizeof(struct PB) == 16, "packed after * ignored");
// stor-layout: an 8-bit field at a byte boundary is a plain QImode field; the
// 13-bit one must not span a 16-byte unit of its over-aligned type.
enum E1 { e1a = 1 };
typedef enum E1 AE1 __attribute__((aligned));
struct Q { long l; AE1 m:24; AE1 n:8; AE1 o:13; AE1 p:19; };
_Static_assert(sizeof(struct Q) == 64, "Q");
