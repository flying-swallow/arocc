// #opt: --target=riscv64-linux-gnuf32 -mcpu=baseline
#if !defined(__riscv_float_abi_single)
#error missing single-float ABI macro
#endif

#if defined(__riscv_float_abi_soft) || defined(__riscv_float_abi_double)
#error incorrect floating-point ABI macro
#endif

int ok;

