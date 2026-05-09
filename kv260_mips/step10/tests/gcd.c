// DESCRIPTION: gcd(48, 18)
// EXPECTED: 6

static int gcd(int a, int b)
{
    int t;
    while (b != 0) {
        t = b;
        b = a % b;
        a = t;
    }
    return a;
}

int main(void)
{
    return gcd(48, 18);
}
