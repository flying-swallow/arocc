// #opt: -Wexpansion-to-defined
#define FOO_IS_DEFINED defined(FOO) // #note@24: expanded from here

#if FOO_IS_DEFINED // #warning@5: macro expansion producing 'defined' has undefined behavior [-Wexpansion-to-defined]
#error FOO should not be defined
#endif

#pragma GCC diagnostic ignored "-Wexpansion-to-defined"

#define FOO
#if !FOO_IS_DEFINED
#error FOO should be defined
#endif

#define DEFINED defined
#if !DEFINED(FOO)
#error FOO should be defined
#endif

#undef FOO
#if DEFINED(FOO)
#error FOO should not be defined
#endif

#define PASTED_DEFINED def ## ined

#if PASTED_DEFINED BAR
#error BAR should not be defined
#endif

#define BAR
#if !PASTED_DEFINED BAR
#error BAR should be defined
#endif

#define DEFINED_MACRO(X) defined(X) // #note@35: expanded from here
#if DEFINED_MACRO(FOO)
#error FOO should not be defined
#endif

#define FOO
#if !DEFINED_MACRO(FOO) // #error@6: macro name must be an identifier
#error Foo should be defined
#endif

#if defined(NOT_DEFINED)
#error NOT_DEFINED should not be defined
#elif !DEFINED ( FOO )
#error FOO should be defined
#endif

