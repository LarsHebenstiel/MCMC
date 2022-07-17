
#ifndef METROPOLIS_H
#define METROPOLIS_H

#include <tuple>

#include "common.cuh"

// Initialize the random state of the curandStateXORWOW variable using a seed
__global__ void RandStateInit(curandStateXORWOW *randState, unsigned long long seed)
{
	int threadId = threadIdx.x + blockIdx.x * blockDim.x;

	// Each thread gets the same seed, a different sequence number, no offset
	// By documentation (https://docs.nvidia.com/cuda/curand/device-api-overview.html#bit-generation-1)
	// this should give a random sequence of *bits* with a period 2 ^ 190
	// Each call to a distribution sample will use some number of those bits.
	// From what I can tell, uniform and normal XORWOW each use 32 bits from the sequence,
	// so the true period for random numbers is actually 2 ^ 185
	// Sequence number (threadId) will bring the state to position 2^67 * sequence in the overall sequence of bits.
	// So each thread actually sits at 2^62 * sequence in the sequence of actual generated numbers.
	// 2 ^ 62 ~= 4 * 10^18, so really there will be no repeat random numbers
	curand_init(seed, threadId, 0, &(randState[threadId]));
}

// Initialize the state of the metropolis algorithm using initSample
__global__ void InitSampleArray(float *prevSample, int initSample, int nNucleons, int totalThreads)
{
	int threadId = threadIdx.x + blockIdx.x * blockDim.x;

	for (int n = 0; n < nNucleons; n++)
	{
		prevSample[totalThreads * n + threadId] = initSample;
	}
}

// Given the previous sample and saved previous sample PDF, use MH algorithm and
// random state to generate next sample in MH chain.
template <float (*pdf)(float)>
__device__ __forceinline__ void MetropolisHastingsStep(float *prevSample, float *invPrevPDF, float stepSize, curandStateXORWOW *randState)
{
	// generate next potential sample
	float nextSample = *prevSample + stepSize * curand_normal(randState);
	float nextPDF = pdf(nextSample);

	// acceptance condition for the new sample
	if (nextPDF * (*invPrevPDF) >= curand_uniform(randState))
	{
		*prevSample = nextSample;
		*invPrevPDF = 1 / nextPDF;
	}
}

// n is NOT nNucleons
template <int totalThreads, int n, PDF pdf>
__device__ __forceinline__ void WarmupCopy(int threadId, float *prevSample, float *localPrevSample, float *localInvPrevPDF)
{
	localPrevSample[n] = prevSample[totalThreads * n + threadId];
	localInvPrevPDF[n] = 1.f / pdf(localPrevSample[n]);
}

template <int totalThreads, int n, PDF pdf, PDF... pdfs>
__device__ __forceinline__ void WarmupCopy(int threadId, float *prevSample, float *localPrevSample, float *localInvPrevPDF)
{
	localPrevSample[n] = prevSample[totalThreads * n + threadId];
	localInvPrevPDF[n] = 1.f / pdf(localPrevSample[n]);
	WarmupCopy<totalThreads, n + 1, pdfs...>(threadId, prevSample, localPrevSample, localInvPrevPDF);
}

template <int n, PDF pdf>
__device__ __forceinline__ void WarmupGibbs(float *localPrevSample, float *localInvPrevPDF, float stepsize, curandStateXORWOW *localRandState)
{
	MetropolisHastingsStep<pdf>(&(localPrevSample[n]), &(localInvPrevPDF[n]), stepsize, localRandState);
}

template <int n, PDF pdf, PDF... pdfs>
__device__ __forceinline__ void WarmupGibbs(float *localPrevSample, float *localInvPrevPDF, float stepsize, curandStateXORWOW *localRandState)
{
	MetropolisHastingsStep<pdf>(&(localPrevSample[n]), &(localInvPrevPDF[n]), stepsize, localRandState);
	WarmupGibbs<n + 1, pdfs...>(localPrevSample, localInvPrevPDF, stepsize, localRandState);
}

// Using previous definitions, run the MH chain for some number of iterations to warm up and reach "steady state"
// This template is for each nucleon with a unique distribution
template <int nNucleons, int totalThreads, PDF... pdfs>
__global__ void WarmupMetropolis(float *prevSample, float stepsize, curandStateXORWOW *randState, int iterations)
{
	if constexpr (sizeof...(pdfs) == 1)
	{
		// Just 1 PDF given, use same for everything
		int threadId = threadIdx.x + blockIdx.x * blockDim.x;
		
		curandStateXORWOW localRandState = randState[threadId];
		float localPrevSample[nNucleons];
		float localInvPrevPDF[nNucleons];
		
		// Just pull first PDF from pack which only contains 1 pdf.
		// somewhat upsetting we can't just pdf = pdfs[0];
		constexpr PDF pdf = std::get<0>(std::forward_as_tuple(pdfs...));
		
		// copy data into local copies
		#pragma unroll nNucleons
		for (int n = 0; n < nNucleons; n++)
		{
			localPrevSample[n] = prevSample[totalThreads * n + threadId];
			localInvPrevPDF[n] = 1 / pdf(localPrevSample[n]);
		}
		
		// Run M-H iterations
		for (int i = 0; i < iterations; i++)
		{
			// Use gibbs sampling to update all variables
			// In our case since P(a, b, ...) = P(a) * P(b) * ...
			// each dimension can just be updated alone
			
			#pragma unroll nNucleons
			for (int n = 0; n < nNucleons; n++)
			{
				MetropolisHastingsStep<pdf>(&(localPrevSample[n]), &(localInvPrevPDF[n]), stepsize, &localRandState);
			}
		}
		
		// store back results
		randState[threadId] = localRandState;
		#pragma unroll nNucleons
		for (int n = 0; n < nNucleons; n++)
		{
			prevSample[totalThreads * n + threadId] = localPrevSample[n];
		}
	}
	else
	{
		// Multiple PDF's given
		// static assert here that length of pdf matches nNucleons
		static_assert(nNucleons == sizeof...(pdfs), "Incorrect number of pdf's");
		int threadId = threadIdx.x + blockIdx.x * blockDim.x;

		curandStateXORWOW localRandState = randState[threadId];
		float localPrevSample[nNucleons];
		float localInvPrevPDF[nNucleons];

		WarmupCopy<totalThreads, 0, pdfs...>(threadId, prevSample, localPrevSample, localInvPrevPDF);

		for (int i = 0; i < iterations; ++i)
		{
			WarmupGibbs<0, pdfs...>(localPrevSample, localInvPrevPDF, stepsize, &localRandState);
		}

		randState[threadId] = localRandState;

		#pragma unroll nNucleons
		for (int n = 0; n < nNucleons; n++)
		{
			prevSample[totalThreads * n + threadId] = localPrevSample[n];
		}
	}
}

#endif // METROPOLIS_H