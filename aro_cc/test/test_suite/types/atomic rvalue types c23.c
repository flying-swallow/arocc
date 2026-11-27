// #skip: diagnostics differ (aro_c3 gap)
// #opt: -std=c23 -ffreestanding -Wno-cast-qualifiers
#include "include/atomic_rvalue_types.h"

#pragma GCC diagnostic warning "-Wcast-qualifiers"

void qualified_atomic_casts(int value) {
    (void)(const _Atomic(int))value; // #warning@11: cast to type 'const _Atomic(int)' will not preserve qualifiers [-Wcast-qualifiers]
    (void)(volatile _Atomic(int))value; // #warning@11: cast to type 'volatile _Atomic(int)' will not preserve qualifiers [-Wcast-qualifiers]
    (void)(const volatile _Atomic(int))value; // #warning@11: cast to type 'const volatile _Atomic(int)' will not preserve qualifiers [-Wcast-qualifiers]
}

