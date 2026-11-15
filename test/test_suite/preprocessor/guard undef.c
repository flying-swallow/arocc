// #opt: -I include
// #error: correct_guard.h:3:5: redefinition of 'x'
// #note: correct_guard.h:3:5: previous definition is here
#include "correct_guard.h"
#undef CORRECT_GUARD_H
#include "correct_guard.h"

