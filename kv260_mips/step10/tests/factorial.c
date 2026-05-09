// DESCRIPTION: factorial(7)
// EXPECTED: 5040

static int fact(int n)
{
    if (n <= 1)
        return 1;
    return n * fact(n - 1);
}

int main(void)
{
    return fact(7);
}
