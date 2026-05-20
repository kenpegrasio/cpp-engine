#include <iostream>
#include <vector>

// Compile this with
// g++ -std=c++20 insights/use_after_free_1.cpp -O1 -g -fno-omit-frame-pointer -fsanitize=address,undefined

int main()
{
    std::vector<int> A = {1, 2, 3};
    int &x = A[0];
    for (int i = 0; i < 100; i++)
    {
        A.push_back(i);
    }
    std::cout << x << std::endl;
    return 0;
}