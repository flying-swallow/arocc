// #opt: -target x86_64-linux
// Incomplete arrays take their bound from the initializer; later lookups see the completed type.
int items[] = {1, 2}; char text[] = "abc";

_Static_assert(_Generic(&items, int (*)[2]: 1, default: 0), "");
_Static_assert(_Generic(&text, char (*)[4]: 1, default: 0), "");
_Static_assert(sizeof(items) == 2 * sizeof(int), "");
_Static_assert(sizeof(text) == 4, "");
