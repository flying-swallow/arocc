  .globl "half_value"
  .data
  .type "half_value", @object
  .size "half_value", 2
  .align 2
"half_value":
  .short  0x3e00
  .globl "float_value"
  .data
  .type "float_value", @object
  .size "float_value", 4
  .align 4
"float_value":
  .long  0x3fc00000
  .globl "double_value"
  .data
  .type "double_value", @object
  .size "double_value", 8
  .align 8
"double_value":
  .quad  0x3ff8000000000000
  .globl "extended_value"
  .data
  .type "extended_value", @object
  .size "extended_value", 10
  .align 16
"extended_value":
  .quad  0x8000000000000000
  .short  0x3fff
  .zero 6
  .globl "quad_value"
  .data
  .type "quad_value", @object
  .size "quad_value", 16
  .align 16
"quad_value":
  .quad  0x0
  .quad  0x3fff000000000000
  .section  .note.GNU-stack,"",@progbits
