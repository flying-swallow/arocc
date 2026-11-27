extern unsigned int aro_backend_answer;
extern const char aro_backend_message[];

int main(void)
{
	const char expected[] = "native backend data";
	if (aro_backend_answer != 42u) return 1;
	for (unsigned long i = 0; i < sizeof(expected); ++i)
	{
		if (aro_backend_message[i] != expected[i]) return (int)i + 2;
	}
	return 0;
}
