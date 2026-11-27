// #opt: --target=riscv64-linux-gnu -mcpu=rv64i
#if !defined(__riscv_float_abi_soft)
#error missing soft-float ABI macro
#endif

#if defined(__riscv_float_abi_single) || defined(__riscv_float_abi_double)
#error incorrect floating-point ABI macro
#endif

#if defined(__riscv_flen)
#error unexpected __riscv_flen
#endif

int ok;

