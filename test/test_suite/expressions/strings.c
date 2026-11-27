// #skip: diagnostics differ (aro_cc gap)
_Static_assert(1, "foo" "\n" "bar");
_Static_assert(1, "foo" "abc\x606262 "); // #error@29: escape sequence out of range
_Static_assert(1, "\000062");
_Static_assert(1, "\U00110000"); // #error@19: invalid universal character
_Static_assert(1, "\u0062"); // #error@19: character 'b' cannot be specified by a universal character name

int a = 'abcde'; // #warning@9: multi-character character constant [-Wmultichar] // #warning@9: character constant too long for its type

_Static_assert(1, "\uD800"); // #error@19: invalid universal character
_Static_assert(1, "\U0000DFFF"); // #error@19: invalid universal character
_Static_assert(1, "\UFFFFFFFF"); // #error@19: invalid universal character
_Static_assert(1, "\u0060");

#pragma GCC diagnostic warning "-Wpedantic"
_Static_assert(1, "aaァ\e[1;"); // #warning@23: use of non-standard escape character '\e' [-Wpedantic]
#pragma GCC diagnostic pop

const char *s1 = (const char *)"hello";
const char *s2 = "hello" + 1;
const char *s3 = "hello" - 1;

char * const string_array[] = {
    "string",
};

