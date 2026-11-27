// #skip: diagnostics differ (aro_c3 gap)
#pragma GCC diagnostic warning "-Wgnu-empty-struct"
#pragma GCC diagnostic warning "-Wc++-compat"

struct {}s; // #warning@1: empty struct is a GNU extension [-Wgnu-empty-struct] // #warning@1: empty struct has size 0 in C, size 1 in C++ [-Wc++-compat]
union {}u; // #warning@1: empty union is a GNU extension [-Wgnu-empty-struct] // #warning@1: empty union has size 0 in C, size 1 in C++ [-Wc++-compat]

