  .globl "false_value"
  .data
  .type "false_value", @object
  .size "false_value", 1
  .align 1
"false_value":
  .byte false
  .globl "true_value"
  .data
  .type "true_value", @object
  .size "true_value", 1
  .align 1
"true_value":
  .byte true
  .section  .note.GNU-stack,"",@progbits
