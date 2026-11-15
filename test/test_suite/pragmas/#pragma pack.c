// #warning: pack.c:2:14: value of #pragma pack(show) == 8
// #warning: pack.c:4:14: value of #pragma pack(show) == 4
// #warning: pack.c:6:14: value of #pragma pack(show) == 16
// #warning: pack.c:7:14: specifying both a name and alignment to 'pop' is undefined
// #warning: pack.c:8:14: value of #pragma pack(show) == 2
// #warning: pack.c:11:14: value of #pragma pack(show) == 16
// #warning: pack.c:14:14: value of #pragma pack(show) == 4
// #warning: pack.c:16:14: value of #pragma pack(show) == 8
// #warning: pack.c:19:14: value of #pragma pack(show) == 16
// #warning: pack.c:21:14: value of #pragma pack(show) == 2
// #warning: pack.c:22:14: #pragma pack(pop, ...) failed: stack empty [-Wignored-pragmas]
// #warning: pack.c:23:14: value of #pragma pack(show) == 2
// #warning: pack.c:24:14: #pragma pack(pop, ...) failed: stack empty [-Wignored-pragmas]
// #warning: pack.c:25:14: value of #pragma pack(show) == 2
// #warning: pack.c:29:13: missing '(' after '#pragma pack' - ignoring [-Wignored-pragmas]
// #warning: pack.c:29:14: unknown action for '#pragma pack' - ignoring [-Wignored-pragmas]
// #warning: pack.c:30:14: expected #pragma pack parameter to be '1', '2', '4', '8', or '16' [-Wignored-pragmas]
// #warning: pack.c:31:20: expected integer or identifier in '#pragma pack' - ignored [-Wignored-pragmas]
#pragma pack()
#pragma pack(show)
#pragma pack(4u)
#pragma pack(show)
#pragma pack(push, r1, 16ll)
#pragma pack(show)
#pragma pack(pop, r1, 2)
#pragma pack(show)

#pragma pack(push, foo, 16)
#pragma pack(show)
#pragma pack(push, bar, 4)
#pragma pack(push, foo, 4)
#pragma pack(show)
#pragma pack()
#pragma pack(show)

#pragma pack(pop, bar)
#pragma pack(show)
#pragma pack(pop, foo)
#pragma pack(show)
#pragma pack(pop, foo)
#pragma pack(show)
#pragma pack(pop, foo)
#pragma pack(show)


#pragma pack
#pragma pack(foo)
#pragma pack(3)
#pragma pack(push, +)
#pragma pack(push, pop)

