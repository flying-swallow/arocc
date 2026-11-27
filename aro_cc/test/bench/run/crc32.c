/* Table-driven CRC-32 over generated data: shifts, xors, table loads. */
#include <stdio.h>
#include <stdlib.h>
int main(void)
{
	unsigned *table = malloc(256 * sizeof(unsigned));
	if (!table) return 1;
	for (unsigned i = 0; i < 256; i++)
	{
		unsigned c = i;
		for (int k = 0; k < 8; k++) c = (c & 1) ? 0xEDB88320u ^ (c >> 1) : c >> 1;
		table[i] = c;
	}
	unsigned long size = 64ul << 20;
	unsigned char *data = malloc(size);
	if (!data) return 1;
	unsigned seed = 12345;
	for (unsigned long i = 0; i < size; i++)
	{
		seed = seed * 1103515245u + 12345u;
		data[i] = (unsigned char)(seed >> 16);
	}
	unsigned crc = 0xFFFFFFFFu;
	for (unsigned long i = 0; i < size; i++) crc = table[(crc ^ data[i]) & 0xFF] ^ (crc >> 8);
	printf("%08x\n", crc ^ 0xFFFFFFFFu);
	free(data);
	free(table);
	return 0;
}
