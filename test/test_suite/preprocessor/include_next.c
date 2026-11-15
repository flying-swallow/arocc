// #opt: -Wgnu-include-next -Wno-gnu-alignof-expression -I include -I include/next -isystem include/system -isystem include/system/next -iquote include/iquote
// #warning: my_include.h:3:2: #include_next is a language extension [-Wgnu-include-next]
// #warning: my_include.h:4:2: #include_next is a language extension [-Wgnu-include-next]
// #warning: same_name.h:1:2: #include_next is a language extension [-Wgnu-include-next]
#include <my_include.h> // include/my_include.h
#include_next <stdalign.h> // #warning@2: #include_next is a language extension [-Wgnu-include-next] // #warning@2: #include_next in primary source file; will search from start of include path [-Winclude-next-outside-header]
#include_next "global_var.h" // #warning@2: #include_next is a language extension [-Wgnu-include-next] // #warning@2: #include_next in primary source file; will search from start of include path [-Winclude-next-outside-header]
#include_next <other.h> // #warning@2: #include_next is a language extension [-Wgnu-include-next] // #warning@2: #include_next in primary source file; will search from start of include path [-Winclude-next-outside-header]
#include_next "same_name.h" // #warning@2: #include_next is a language extension [-Wgnu-include-next] // #warning@2: #include_next in primary source file; will search from start of include path [-Winclude-next-outside-header]
#include_next <same_name_system.h> // #warning@2: #include_next is a language extension [-Wgnu-include-next] // #warning@2: #include_next in primary source file; will search from start of include path [-Winclude-next-outside-header]
_Static_assert(FOO == 1, "Did not include correct file");
_Static_assert(BAR == 2, "Did not include_next correct file");
_Static_assert(alignof(multiple) == _Alignof(int), "#include_next quotes");
_Static_assert(OTHER_INCLUDED == 1, "OTHER_INCLUDED");
_Static_assert(NEXT_OTHER_INCLUDED == 1, "NEXT_OTHER_INCLUDED");
_Static_assert(HAS_INCLUDE_NEXT_WORKED == 1, "HAS_INCLUDE_NEXT_WORKED");
_Static_assert(NEXT_SAME_NAME_INCLUDED == 1, "NEXT_SAME_NAME_INCLUDED");
_Static_assert(SYSTEM_NEXT_SAME_NAME_INCLUDED == 1, "SYSTEM_NEXT_SAME_NAME_INCLUDED");

#if __has_include_next("stdalign.h") // #warning@5: #include_next in primary source file; will search from start of include path [-Winclude-next-outside-header]
#define TOP_LEVEL_INCLUDE_NEXT 1
#endif
_Static_assert(TOP_LEVEL_INCLUDE_NEXT == 1, "TOP_LEVEL_INCLUDE_NEXT");

