// DESCRIPTION: sum 1+2+...+10
// EXPECTED: 55

int main(void)
{
    int sum = 0;
    int i;
    for (i = 1; i <= 10; i++)
        sum += i;
    return sum;
}
