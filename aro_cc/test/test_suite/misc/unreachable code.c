int test(int a){
	switch(a) {
		default: break;
	}
	return 1;
}
int test1(int a){
	switch(a) {
		break;
		a=1; // #warning@3: unreachable code [-Wunreachable-code]
	}
	return 1;
}
int test2(int a){
	switch(a) {
		return 1;
		a=1; // #warning@3: unreachable code [-Wunreachable-code]
	}
	return 1;
}
int compound_stmt(int a){
	{
		a=1;
		return 1;
		a=2; // #warning@3: unreachable code [-Wunreachable-code]
	}
}
int if_then_else(int a){
	if(a)
		return 1;
	else
		return 2;
	return 3; // #warning@2: unreachable code [-Wunreachable-code]
}

