#define FOO 1 // #note@9: previous definition is here
#define FOO 2 // #warning@9: 'FOO' macro redefined [-Wmacro-redefined] // #note@9: previous definition is here
#define FOO 3 // #warning@9: 'FOO' macro redefined [-Wmacro-redefined]
#define FOO 3

#define BAR 1 /* fjfao */  /* fjfao */ 2
#define BAR 1 2

#define BAZ + /* fjfao */  /* fjfao */ / // #note@9: previous definition is here
#define BAZ +/ // #warning@9: 'BAZ' macro redefined [-Wmacro-redefined]

#define QUX 1 /* FJDLKS */
#define QUX 1

