// #opt: --target=x86_64-windows-msvc
__pragma(once) // #warning@10: #pragma once in main file [-Wpragma-once-outside-header]
#define PRAGMA(x) __pragma(x)

PRAGMA(message "foo") // #note@1: #pragma message: foo

int __identifier(int);

__identifier() // #error@1: expected identifier argument
__identifier(1) // #error@14: cannot convert a number to an identifier
__identifier(a b) // #error@16: missing ')', after identifier

