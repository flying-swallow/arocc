// #opt: -pedantic
#define int foo // #warning@9: keyword is hidden by macro definition [-Wkeyword-macro]
#define include hello
#include <stdbool.h>
#define if then // #warning@9: keyword is hidden by macro definition [-Wkeyword-macro]
#define alignof _Alignof

unsigned x; // only here to suppress -Wempty-translation-unit

