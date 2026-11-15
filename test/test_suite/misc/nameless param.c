int xyz(float);

void foo(int) { // #warning@10: omitting the parameter name in a function definition is a C23 extension [-Wc23-extensions]
    return;
}

void bar(float, char) { // #warning@10: omitting the parameter name in a function definition is a C23 extension [-Wc23-extensions] // #warning@17: omitting the parameter name in a function definition is a C23 extension [-Wc23-extensions]
    return;
}

