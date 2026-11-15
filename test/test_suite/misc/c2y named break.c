// #skip: diagnostics differ (aro_c3 gap)
// #opt: -std=c2y
static void named_break(int a) {
    loop: while (true) {
        while (true) {
            if (a) continue loop;
        }
        break loop;
    }
    sw: switch (a) {
        case 1:
            break sw;
        case 2:
            continue sw; // #error@22: 'continue' label refers to a switch statement
    }
    other:;
    for (;;) {
        #pragma GCC diagnostic warning "-Wc2y-extensions"
        continue other; // #warning@18: named 'continue' is a C2y extension [-Wc2y-extensions] // #error@18: 'continue' label does not name an enclosing loop or switch
    }
}

