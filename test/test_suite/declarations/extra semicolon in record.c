// #opt: -Wextra-semi
// An empty member declaration (`int a;;`) is accepted as an extension
// (linux/nfc.h `char service_name[N]; /* ... */;`).
struct s { int a;; int b; }; // #warning@18: extra ';' inside a struct
union u { ; int c; }; // #warning@11: extra ';' inside a union
_Static_assert(sizeof(struct s) == 2 * sizeof(int), "members unaffected");
