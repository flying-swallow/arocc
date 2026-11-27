// #skip: diagnostics differ (aro_c3 gap)
// #opt: -fms-extensions -Wno-microsoft-include
#include "include\other.h"

#ifndef OTHER_INCLUDED
#error backslash in include should work
#endif

#undef OTHER_INCLUDED
#include "include/ms-ext/include other.h"

#ifndef OTHER_INCLUDED
#error Microsoft search rule should work
#endif

don't mind me ;)

