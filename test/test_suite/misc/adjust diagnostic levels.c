#define FOO 1 // #note@9: previous definition is here
#define FOO 2 // #warning@9: 'FOO' macro redefined [-Wmacro-redefined]

#pragma GCC diagnostic error "-Wmacro-redefined"
#define BAR 1 // #note@9: previous definition is here
#define BAR 2 // #error@9: 'BAR' macro redefined [-Werror,-Wmacro-redefined]

#pragma GCC diagnostic push

#pragma GCC diagnostic ignored "-Wmacro-redefined"
#define BAZ 1
#define BAZ 2

#pragma GCC diagnostic pop
#pragma GCC diagnostic pop

#define QUX 1 // #note@9: previous definition is here
#define QUX 2 // #warning@9: 'QUX' macro redefined [-Wmacro-redefined]

#pragma GCC diagnostic push
#pragma GCC diagnostic error "-Wpedantic"
#pragma GCC diagnostic pop
struct Foo {};

