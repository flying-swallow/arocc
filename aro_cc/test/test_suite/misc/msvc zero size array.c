// #skip: diagnostics differ (aro_c3 gap)
// #opt: --target=x86_64-windows-msvc
typedef int J[];

#pragma pack(1)
struct J_packed {
    J a;
};

_Static_assert(sizeof(J) == 0, "incorrect size"); // #warning@16: sizeof returns 0
_Static_assert(_Alignof(J) == 4, "incorrect alignment");

struct J_size {
    char a[sizeof(J)+1]; // #warning@12: sizeof returns 0
    char b;
};

_Static_assert(sizeof(struct J_size) == 2, "incorrect size");
_Static_assert(_Alignof(struct J_size) == 1, "incorrect alignment");

struct J_extra_alignment {
    char a;
    J b;
};
struct J_extra_alignment var83;

_Static_assert(sizeof(J) == 0, ""); // #warning@16: sizeof returns 0
_Static_assert(_Alignof(J) == 4, "");

