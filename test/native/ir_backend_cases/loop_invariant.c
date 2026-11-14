// expect 60
int abs(int);

int main(void)
{
	int invariant = abs(-3);
	int sum = 0;
	for (int i = 0; i < 4; i++)
	{
		for (int j = 0; j < 5; j++) sum += invariant;
	}
	return sum;
}
