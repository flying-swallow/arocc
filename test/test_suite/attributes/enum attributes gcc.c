// #skip: diagnostics differ (aro_c3 gap)
// #opt: --emulate=gcc
enum __attribute__((vector_size(32))) VectorSize2 { // #error@21: invalid vector element type 'enum VectorSize2'
    A
};

