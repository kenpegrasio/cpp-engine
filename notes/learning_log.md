# Learning Log

## 1

`const Order* order` implies `order` is a pointer to constant `Order` object. 

`Order* const order` implies `order` is a constant pointer to `Order` object. 

## 2

`-fsanitize=address` enables AddressSanitizer. This cannot be combined with `-fsanitize=thread` as mentioned in this [documentation](https://gcc.gnu.org/onlinedocs/gcc/Instrumentation-Options.html). 

`-fsanitize=thread` enables the ThreadSanitizer. This cannot be combined with `-fsanitize=address` as mentioned in this [documentation](https://gcc.gnu.org/onlinedocs/gcc/Instrumentation-Options.html). 

`-fsanitize=undefined` enables UndefinedBehaviorSanitizer. It catches selected runtime-checkable undefined behavior. 

Use `-fno-omit-frame-pointer` to improve stack traces. 

`-I<folder-name>` means you are telling the compiler to add the `folder-name` to the compiler's header search path. 

## 3

> Here's how a deque<Tp> manages memory.  Each deque has 4 members:
>    - Tp**        _M_map
>    - size_t      _M_map_size
>    - iterator    _M_start, _M_finish
>
>    map_size is at least 8.  %map is an array of map_size
>    pointers-to-@a nodes.  (The name %map has nothing to do with the
>    std::map class, and @b nodes should not be confused with
>    std::list's usage of @a node.)
>
>    A @a node has no specific type name as such, but it is referred
>    to as @a node in this file.  It is a simple array-of-Tp.  If Tp
>    is very large, there will be one Tp element per node (i.e., an
>    @a array of one).  For non-huge Tp's, node size is inversely
>    related to Tp size: the larger the Tp, the fewer Tp's will fit
>    in a node.  The goal here is to keep the total size of a node
>    relatively small and constant over different Tp's, to improve
>    allocator efficiency.
>
>    Not every pointer in the %map array will point to a node.  If
>    the initial number of elements in the deque is small, the
>    /middle/ %map pointers will be valid, and the ones at the edges
>    will be unused.  This same situation will arise as the %map
>    grows: available %map pointers, if any, will be on the ends.  As
>    new nodes are created, only a subset of the %map's pointers need
>    to be copied @a outward.

## 4

To update C++ Intellisense to syntax check according to the correct version:
1. Press Ctrl + Shift + P (or Cmd + Shift + P on Mac) to open the Command Palette.
2. Type and select C/C++: Edit Configurations (UI).
3. Scroll down to the C++ Standard dropdown field.
4. Select your desired version (e.g., c++20, c++23).

## 5

You cannot call `resize` in `std::vector<std::mutex>`. From the cppreference for `resize`, the following type requirements are stated:

> T must meet the requirements of MoveInsertable and DefaultInsertable in order to use overload (`void resize( size_type count );`).  
> T must meet the requirements of CopyInsertable in order to use overload (`void resize( size_type count, const value_type& value );`). 

Well, next question is that what is MoveInsertable?

> If std::allocator<T> or a similar allocator is used, a class does not have to implement a move constructor to satisfy this type requirement: a copy constructor that takes a const T& argument can bind rvalue expressions. If a MoveInsertable class implements a move constructor, it may also implement move semantics to take advantage of the fact that the value of rv after construction is unspecified. 

Basically, in short, the object must have either move constructor or copy constructor. However, the documentation for `std::mutex` itself states that it is neither copyable nor movable. That is why you cannot call `resize` in `std::vector<std::mutex>`. 