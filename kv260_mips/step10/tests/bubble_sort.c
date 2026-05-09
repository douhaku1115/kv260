// DESCRIPTION: bubble_sort({5,3,1,4,2}) min
// EXPECTED: 1

static void sort(int *a, int n)
{
    int i, j, t;
    for (i = 0; i < n - 1; i++) {
        for (j = 0; j < n - i - 1; j++) {
            if (a[j] > a[j + 1]) {
                t      = a[j];
                a[j]   = a[j + 1];
                a[j + 1] = t;
            }
        }
    }
}

int main(void)
{
    int arr[5];
    arr[0] = 5;
    arr[1] = 3;
    arr[2] = 1;
    arr[3] = 4;
    arr[4] = 2;
    sort(arr, 5);
    return arr[0];   // ソート後の最小値
}
