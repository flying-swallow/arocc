// #skip: diagnostics differ (aro_c3 gap)
// #opt: -target aarch64-windows-msvc --emulate=clang -fdeclspec
// #todo: TODO aligned bitfield in clang emulation mode targeting msvc abi
typedef struct {
    __declspec(align(128)) int bit : 1;
} AnonymousAlignedBitfield;

_Static_assert(sizeof(AnonymousAlignedBitfield) == 128, ""); // #error@16: static assertion failed due to requirement 'sizeof(struct (anonymous struct at msvc anonymous default pack clang.c:1:9)) == 128' // #note@49: expression evaluates to '8 == 128'
_Static_assert(_Alignof(AnonymousAlignedBitfield) == 128, "");

