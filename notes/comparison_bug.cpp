#include <iostream>

int main()
{
    int x{-1};
    unsigned long long y{100};
    if (x >= y)
        std::cout << "-1 is >= 100" << std::endl;
    else
        std::cout << "-1 is < 100" << std::endl;
}