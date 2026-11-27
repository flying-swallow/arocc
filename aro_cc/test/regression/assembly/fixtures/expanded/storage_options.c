  .globl "common_zero"
  .comm "common_zero", 4, 4
  .local "sectioned_value"
  .section .data."sectioned_value","aw",@progbits
  .type "sectioned_value", @object
  .size "sectioned_value", 4
  .align 4
"sectioned_value":
  .long 9
  .globl "tls_value"
  .section .tdata."tls_value","awT",@progbits
  .type "tls_value", @object
  .size "tls_value", 4
  .align 4
"tls_value":
  .long 7
  .globl "tls_zero"
  .section .tbss."tls_zero","awT",@nobits
  .align 4
"tls_zero":
  .zero 4
  .section  .note.GNU-stack,"",@progbits
