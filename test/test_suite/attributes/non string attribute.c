// #skip: diagnostics differ (aro_cc gap)
enum E {
   is_deprecated_with_msg __attribute__((deprecated("I am deprecated" = 5 ))), // #error@71: array type 'char [16]' is not assignable // #error@71: expected string literal as argmuent of 'deprecated' attribute
};

