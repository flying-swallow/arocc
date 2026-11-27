// #skip: diagnostics differ (aro_cc gap)
#pragma GCC diagnostic warning "-Wgnu-statement-expression"

int g = ({ // #warning@10: use of GNU statement expression extension [-Wgnu-statement-expression] // #error@10: statement expression not allowed at file scope
    int x = 5;
    x + 10;
});
#pragma GCC diagnostic ignored "-Wgnu-statement-expression"

void foo(void) {
    int x = ({}); // #error@13: initializing 'int' from incompatible type 'void'
    ({ 1; }); // #warning@8: expression result unused [-Wunused-value]
    ({ 2; 3; }); // #warning@8: expression result unused [-Wunused-value] // #warning@11: expression result unused [-Wunused-value]
    int y = ({
        int z = 5;
        z += 10;
        z;
    });
    z++; // #error@5: use of undeclared identifier 'z'
    ({foo;})();
}

void self_referential_initializer(void) {
    int x = ({
        x = 5;
    });
}

