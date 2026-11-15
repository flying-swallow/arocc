// #skip: diagnostics differ (aro_c3 gap)
// #opt: --target=x86_64-linux-gnu
__fp16 foo(__fp16 param) { // #error@19: parameters cannot have __fp16 type; did you forget * ? // #error@11: function return value cannot have __fp16 type; did you forget * ?
    return 0;
}

