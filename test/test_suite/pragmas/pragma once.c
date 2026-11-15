// #error: global_var.h:1:5: redefinition of 'multiple'
// #note: global_var.h:1:5: previous definition is here
#include "include/global_var.h"
#include "include/global_var.h"

#include "include/global_var_once.h"
#include "include/global_var_once.h"

#pragma once // #warning@9: #pragma once in main file [-Wpragma-once-outside-header]
#pragma once // #warning@9: #pragma once in main file [-Wpragma-once-outside-header]

