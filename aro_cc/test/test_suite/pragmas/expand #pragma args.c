// #opt: --target=x86_64-linux-gnu
#undef _CRT_PACKING
#define _CRT_PACKING 16
#pragma pack(show) // #warning@14: value of #pragma pack(show) == 8
#pragma pack(push,_CRT_PACKING)
#pragma pack(show) // #warning@14: value of #pragma pack(show) == 16
#pragma pack(pop)
#pragma pack(show) // #warning@14: value of #pragma pack(show) == 8

#define PRAGMA_ACTION push
#define PRAGMA_AMOUNT 16
_Pragma("pack(PRAGMA_ACTION, PRAGMA_AMOUNT)");
#pragma pack(show) // #warning@14: value of #pragma pack(show) == 16
#pragma pack(pop)
#pragma pack(show) // #warning@14: value of #pragma pack(show) == 8


#define P(s) _Pragma(#s)
#define WHY(x, y) P(pack(x, y));

WHY(push, 16)
#pragma pack(show) // #warning@14: value of #pragma pack(show) == 16
#pragma pack(pop)

