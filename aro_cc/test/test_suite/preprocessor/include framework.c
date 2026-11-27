// #opt: -iframework frameworks -iframework include/next
#include <SimpleFramework/Foo.h>
_Static_assert(SIMPLE_FRAMEWORK_FOO == 123, "macro from framework not accessible");
_Static_assert(SIMPLE_FRAMEWORK_FOO_NEXT == 123, "macro from framework not accessible");

