  .globl "local_zero"
  .bss
  .align 4
"local_zero":
  .zero 4
  .globl "tls_value"
  .section .tdata,"awT",@progbits
  .type "tls_value", @object
  .size "tls_value", 4
  .align 4
"tls_value":
  .long 7
  .local "sectioned_value"
  .data
  .type "sectioned_value", @object
  .size "sectioned_value", 4
  .align 4
"sectioned_value":
  .long 9
  .globl "tls_zero"
  .section .tbss,"awT",@nobits
  .align 4
"tls_zero":
  .zero 4
  .section  .note.GNU-stack,"",@progbits
