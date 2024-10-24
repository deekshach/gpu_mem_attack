This directory provides the PoC for code reuse and code injection attacks for cuda applications.

# Code Structure

The major components in `poc.cu` are as follows:
- sum1: a device function to calculate the summation of given items in a GPU buffer. sum1 is a recursive function;
the number of recursion is decided by the number of items to sum.

- sum2: a device function similar to sum1. The only difference is that sum2 adds a value of 10 to the summation
before returning it.

- k1: a kernel function that calls sum1 to get the summation of items in a given GPU buffer.• linked data pages: GPU memory pages allocated using cudaMalloc(). Each of these pages is filled with a BRA instruction. For the first few pages, the target of the BRA instruction is the page next to it. For the last page, the target is sum2.

poc.cu takes a user input. Depending on the user input,
a buffer overflow might be triggered. When there is no buffer overflow, the code executes following the benign control flow in Figure 1 (a); if buffer overflow is triggered, the code follows the malicious control flow:

- Benign control flow. When k1 executes, it calls the device function sum1, which should return the summation of speficified items within a given buffer (stored in GPU global
memory). In this PoC, we calculate the summation of two items in the buffer; thus the recursion count for sum1 is 1. After sum1 calculates the summation, the result is returned to k1. k1 copies this result to CPU memory and then the result is printed. Note that in this benign scenario, sum2 is never invoked and
the linked data pages are not utilized.

- Malicious control flow. The malicious scenario begins in the same way as the benign scenario: k1 calls sum1, and then sum1 calls sum1. However, before sum1 returns (to sum1), a buffer overflow is triggered and the return address is overwritten with the address of the first linked data page. Thus, when sum1 returns, instead of returning to sum1 (recursive call), it returns to the the first linked data page. Then, it executes the BRA instruction in the page and jumps to the next linked data page. This “execute-and-jump” pattern is repeated several times until the execution eventually reaches the last linked data page. Then, it jumps to sum2. sum2 finishes calculating the summation but adds an extra 10 to the result before returning it to k1.


# Test the PoC on your GPU

Follow the steps below to test the PoC on your GPU:

- Turn off ASLR, this is to ensure that the virtual addresses do no change across runs.

```
echo 0 | sudo tee /proc/sys/kernel/randomize_va_space
```

- Compile the code.

```
make
```

- Run the code in cuda-gdb to get the following information.
    - the address of the first linked data page.
    - the address of sum1.
    - the address of sum2.
    - the distance between the local array (arr) and the return address on the stack in sum1. Note 
      that in this PoC, sum1 is called twice, once by k1, once by sum1 (recursive). We need to know 
      this distance on the stack during the second execution of sum1 (called by sum1).
    - the return address in sum1 (again, when it's called by sum1).
    
- Modify line 24 to line 28 in poc.cu, based on the results obtained in the last step.

- Modify line 43 in poc.cu, to determine whether or not a buffer overflow will be triggered 
during the execution.

- Recompile the code.

- Run the code and check the printed result:
    - In the benign scenario, the result should be 1.
    - In the malicious scenario, the result should be 11 (1+10).
    
    
# Platform

This code is made for sm_86. To test it with other CUDA capabilities, modify the compilation flags in Makefile.

# Contact

Please contact Yanan Guo (yanan.guo@rochester.edu) for any questions.
