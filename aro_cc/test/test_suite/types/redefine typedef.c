typedef int MyInt; // #note@13: previous definition is here
int foo(MyInt MyInt) {
	return MyInt;
}

int MyInt; // #error@5: redefinition of 'MyInt' as different kind of symbol

enum E {
	Foo, // #note@2: previous definition is here
};

typedef int Foo; // #error@13: redefinition of 'Foo' as different kind of symbol

