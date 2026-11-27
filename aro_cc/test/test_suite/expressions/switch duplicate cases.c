#pragma GCC diagnostic ignored "-Wc2y-extensions"
void chained(int arg) {
    switch (arg) {
        case 1: case 2: case 1: // #note@14: previous case defined here // #error@30: duplicate case value '1'
        case 4 ... 6: case 5: // #note@14: previous case defined here // #error@28: duplicate case value '5'
        case 8: case 7 ... 9: // #note@14: previous case defined here // #error@22: duplicate case value '7'
        default: default: // #error@9: multiple default cases in the same switch // #note@18: previous case defined here
            break;
    }
}
