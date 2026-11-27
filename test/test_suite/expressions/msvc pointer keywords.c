// #skip: diagnostics differ (aro_cc gap)
// #opt: --target=x86_64-windows-msvc -std=c23
// #todo: TODO: reimplement msvc pointer attribute keywords
#include <stddef.h>

typedef void *__ptr64 HANDLE64; // #warning@15: TODO: implement 'ptr64' attribute
_Static_assert(sizeof(HANDLE64) == 8, "");
_Static_assert(_Alignof(HANDLE64) == 8, "");

typedef void *__ptr32 HANDLE32; // #warning@15: TODO: implement 'ptr32' attribute
_Static_assert(sizeof(HANDLE32) == 4, ""); // #error@16: static assertion failed due to requirement 'sizeof(void *) == 4' // #note@33: expression evaluates to '8 == 4'
_Static_assert(_Alignof(HANDLE32) == 4, ""); // #error@16: static assertion failed due to requirement '_Alignof(void *) == 4' // #note@35: expression evaluates to '8 == 4'

int *__ptr64 __ptr32 p1; // #warning@6: TODO: implement 'ptr64' attribute // #warning@14: TODO: implement 'ptr32' attribute
int *__sptr __uptr p2; // #warning@6: TODO: implement 'sptr' attribute // #warning@13: TODO: implement 'uptr' attribute
int *__ptr64 __ptr64 p3; // #warning@6: TODO: implement 'ptr64' attribute // #warning@14: TODO: implement 'ptr64' attribute

int __ptr64 x; // #warning@5: TODO: implement 'ptr64' attribute
typedef nullptr_t __ptr64 sized_nullptr; // #warning@19: TODO: implement 'ptr64' attribute

