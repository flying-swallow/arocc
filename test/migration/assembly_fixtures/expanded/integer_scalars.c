  .globl "byte_value"
  .data
  .type "byte_value", @object
  .size "byte_value", 1
  .align 1
"byte_value":
  .byte 255
  .globl "short_value"
  .data
  .type "short_value", @object
  .size "short_value", 2
  .align 2
"short_value":
  .short -123
  .globl "int_value"
  .data
  .type "int_value", @object
  .size "int_value", 4
  .align 4
"int_value":
  .long 305419896
  .globl "long_value"
  .data
  .type "long_value", @object
  .size "long_value", 8
  .align 8
"long_value":
  .quad 123456789
  .section  .note.GNU-stack,"",@progbits
