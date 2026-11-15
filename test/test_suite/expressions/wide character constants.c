// #opt: -Wfour-char-constants -Wno-c23-extensions
/*

    A multiline comment to test that the linenumber is correct.

*/
#include <stddef.h>
_Static_assert(sizeof L' ' == sizeof(wchar_t), "sizes don't match");
unsigned short a = u'￿' + u'𐀁'; // #error@27: character too large for enclosing character literal type // #warning@20: implicit conversion from 'int' to 'unsigned short' changes non-zero value from 131072 to 0 [-Wconstant-conversion]
_Static_assert(L'ab' == 'b', "expected to match"); // #error@16: wide character literals may not contain multiple characters
_Static_assert(U'ab' == 'b', "should not be evaluated"); // #error@16: Unicode character literals may not contain multiple characters
_Static_assert('\1' == 0x01, "");
#if __INT_MAX__ >= 0x01020304
_Static_assert('\1\2\3\4' == 0x01020304, ""); // #warning@16: multi-character character constant [-Wfour-char-constants]
#endif

_Static_assert(sizeof(u'a') == 2, "");
_Static_assert(sizeof(U'a') == 4, "");
unsigned long A = U'\xFFFFFFFF';
unsigned long B = u'\xFFFFFFFF'; // #error@21: escape sequence out of range
unsigned long C = U'𝒵';  // U+1D4B5
unsigned long D = u'𝒵';  // U+1D4B5 // #error@19: character too large for enclosing character literal type
unsigned long E = U'ℤ';  // U+2124
unsigned long F = u'ℤ';  // U+2124
unsigned long G = U'\UFFFFFFFF'; // #error@20: invalid universal character
unsigned long H = u'\U0001D4B5'; // #error@19: character too large for enclosing character literal type
unsigned long I = U'ab'; // #error@19: Unicode character literals may not contain multiple characters
unsigned long J = u'ab'; // #error@19: Unicode character literals may not contain multiple characters
unsigned long K = '\777'; // #error@20: escape sequence out of range
wchar_t L = L'\777';

_Static_assert(sizeof(u8'a') == sizeof(char), "");
int M = u8'ab'; // #error@9: Unicode character literals may not contain multiple characters
int N = u8'\xFF';
int O = u8'™'; // #error@9: character too large for enclosing character literal type
int P = u8'\u0041'; // #error@9: character 'A' cannot be specified by a universal character name
int Q = u8'\x41';
int R = u8'\u0024';
int S = '\x'; // #error@9: \x used with no following hex digits
int T = '\xg'; // #error@9: \x used with no following hex digits
int U = '\8'; // #warning@10: unknown escape sequence '\8' [-Wunknown-escape-sequence]
int V = '\	'; // tab character // #warning@10: unknown escape sequence '\x09' [-Wunknown-escape-sequence]
_Static_assert('\(' == '(', "");
_Static_assert('\[' == '[', "");
_Static_assert('\{' == '{', "");
_Static_assert('\%' == '%', "");
int W = '\u'; // #error@9: \u used with no following hex digits
int X = '\U'; // #error@9: \U used with no following hex digits
#pragma GCC diagnostic warning "-Wpedantic"
int Y = 'abc\E'; // #warning@13: use of non-standard escape character '\E' [-Wpedantic] // #warning@9: multi-character character constant [-Wfour-char-constants]
#pragma GCC diagnostic pop
int Z = 'ABC\D'; // #warning@13: unknown escape sequence '\D' [-Wunknown-escape-sequence] // #warning@9: multi-character character constant [-Wfour-char-constants]

_Static_assert(sizeof(__CHAR16_TYPE__) == sizeof(u'A'), "");
_Static_assert(sizeof(__CHAR32_TYPE__) == sizeof(U'A'), "");

