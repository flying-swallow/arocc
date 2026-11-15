// #kind: expand_error
#pragma GCC diagnostic warning "-Wunknown-pragmas"

#pragma unknown_option // #warning@9: unknown pragma ignored [-Wunknown-pragmas]

#pragma GCC unknown_option // #warning@13: pragma GCC expected 'error', 'warning', 'diagnostic', 'poison' [-Wunknown-pragmas]

#pragma GCC diagnostic unknown_option_again // #warning@24: pragma GCC diagnostic expected 'error', 'warning', 'ignored', 'fatal', 'push', or 'pop' [-Wunknown-pragmas]

