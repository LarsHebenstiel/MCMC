#ifndef COMMON_H
#define COMMON_H

#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wdouble-promotion" // CUDA kernel has double promotion errors lmao

#include <cuda.h>
#include <cuda_runtime.h>               // Stops underlining of __global__
#include <device_launch_parameters.h>   // Stops underlining of threadIdx etc.
#include <curand_kernel.h>

#pragma GCC diagnostic pop

#include <stdio.h>

#define cudaCheckError() { \
  cudaError_t err = cudaGetLastError(); \
  if(err != cudaSuccess) { \
    printf("Cuda error: %s:%d: %s\n", __FILE__, __LINE__, cudaGetErrorString(err)); \
    exit(1); \
  } \
}

// http://tdesell.cs.und.edu/files/cuda_device_query.cu
// Print device properties
// Get cudaDeviceProp using getCudaDeviceProp()
void printDevProp(cudaDeviceProp devProp)
{
    printf("  Major revision number:         %d\n",  devProp.major);
    printf("  Minor revision number:         %d\n",  devProp.minor);
    printf("  Name:                          %s\n",  devProp.name);
    printf("  Total global memory:           %lu\n",  devProp.totalGlobalMem);
    printf("  Total shared memory per block: %lu\n",  devProp.sharedMemPerBlock);
    printf("  Total registers per block:     %d\n",  devProp.regsPerBlock);
    printf("  Warp size:                     %d\n",  devProp.warpSize);
    printf("  Maximum memory pitch:          %lu\n",  devProp.memPitch);
    printf("  Maximum threads per block:     %d\n",  devProp.maxThreadsPerBlock);
    for (int i = 0; i < 3; ++i)
    printf("  Maximum dimension %d of block:  %d\n", i, devProp.maxThreadsDim[i]);
    for (int i = 0; i < 3; ++i)
    printf("  Maximum dimension %d of grid:   %d\n", i, devProp.maxGridSize[i]);
    printf("  Clock rate:                    %d\n",  devProp.clockRate);
    printf("  Total constant memory:         %lu\n",  devProp.totalConstMem);
    printf("  Texture alignment:             %lu\n",  devProp.textureAlignment);
    printf("  Concurrent copy and execution: %s\n",  (devProp.deviceOverlap ? "Yes" : "No"));
    printf("  Number of multiprocessors:     %d\n",  devProp.multiProcessorCount);
    printf("  Kernel execution timeout:      %s\n",  (devProp.kernelExecTimeoutEnabled ? "Yes" : "No"));
    printf("  Memory Clock Rate (KHz):       %d\n", devProp.memoryClockRate);
    printf("  Memory Bus Width (bits):       %d\n", devProp.memoryBusWidth);
    printf("  Peak Memory Bandwidth (GB/s):  %f\n", 2.0 * devProp.memoryClockRate * (devProp.memoryBusWidth / 8) / 1.0e6);
    return;
}

void printCudaDevices() {
    // Number of CUDA devices
    int devCount;
    cudaGetDeviceCount(&devCount);
    cudaCheckError();
    printf("CUDA Device Query...\n");
    printf("There are %d CUDA devices.\n", devCount);
 
    // Iterate through devices
    for (int i = 0; i < devCount; ++i)
    {
        // Get device properties
        printf("\nCUDA Device #%d\n", i);
        cudaDeviceProp devProp;
        cudaGetDeviceProperties(&devProp, i);
        cudaCheckError();
        printDevProp(devProp);
    }
}

int cudaCores(int device) {
    cudaDeviceProp devProp;
    cudaGetDeviceProperties(&devProp, device);
    cudaCheckError();
    
    int cores = 0;
    int mp = devProp.multiProcessorCount;
    switch (devProp.major){
        case 2: // Fermi
            if (devProp.minor == 1) cores = mp * 48;
            else cores = mp * 32;
            break;
        case 3: // Kepler
            cores = mp * 192;
            break;
        case 5: // Maxwell
            cores = mp * 128;
            break;
        case 6: // Pascal
            if ((devProp.minor == 1) || (devProp.minor == 2)) cores = mp * 128;
            else if (devProp.minor == 0) cores = mp * 64;
            else printf("Unknown device type\n");
            break;
        case 7: // Volta and Turing
            if ((devProp.minor == 0) || (devProp.minor == 5)) cores = mp * 64;
            else printf("Unknown device type\n");
            break;
        case 8: // Ampere
            if (devProp.minor == 0) cores = mp * 64;
            else if (devProp.minor == 6) cores = mp * 128;
            else printf("Unknown device type\n");
            break;
        default:
            printf("Unknown device type\n"); 
            break;
    }
    return cores;
}

#endif // COMMON_H
