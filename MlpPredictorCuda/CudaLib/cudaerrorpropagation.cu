#include "cudaerrorpropagation.h"

#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <math.h>
#include <float.h>

#include "cuda_runtime.h"
#include "device_launch_parameters.h"
#include "curand.h"

#define A 1.2f
#define B 0.5f
#define MIN_LEARNING_RATE FLT_MIN
//#define MIN_LEARNING_RATE 0.000001f
#define MAX_LEARNING_RATE 50.0f

// Device functions

// Array[height * width] 
__device__ long index2D(int i, int j, int width)
{
	return i * width + j;
}

// Array[depth * height * width]
__device__ long index3D(int i, int j, int k, int height, int width)
{
	return (i * height + j) * width + k;
}

__device__ float unipolarSigmoidFunction(float x)
{
	return 1.0f / (1.0f + expf(-x));
}

__device__ float unipolarSigmoidDerivative(float fX)
{
	return fX * (1.0f - fX);
}

__device__ float bipolarSigmoidFunction(float x)
{
	return tanhf(x);
}

__device__ float bipolarSigmoidDerivative(float fX)
{
	return 1.0f - fX * fX;;
}

__device__ float sinusoidFunction(float x)
{
	return sinf(x);
}

__device__ float sinusoidDerivative(float fX)
{
	return sqrtf(1.0f - fX * fX);
}

__device__ float linearFunction(float x)
{
	return x;
}

__device__ float linearDerivative(float fX)
{
	return 1.0f;
}

__device__ int sign(float x)
{
	if (x > 0.0f) return 1;
	if (x < 0.0f) return -1;
	return 0;
}

// Pointers to device functions

__device__ func_ptr pUnipolarSigmoidFunction = unipolarSigmoidFunction;
__device__ func_ptr pUnipolarSigmoidDerivative = unipolarSigmoidDerivative;

__device__ func_ptr pBipolarSigmoidFunction = bipolarSigmoidFunction;
__device__ func_ptr pBipolarSigmoidDerivative = bipolarSigmoidDerivative;

__device__ func_ptr pSinusoidFunction = sinusoidFunction;
__device__ func_ptr pSinusoidDerivative = sinusoidDerivative;

__device__ func_ptr pLinearFunction = linearFunction;
__device__ func_ptr pLinearDerivative = linearDerivative;

// Cuda kernels

__global__ void computeLayerOutputBatchKernel(func_ptr layerActivationFunc, const float *layerInsBatch /*2d*/,
	const float *layerWeights /*2d*/, float *layerOutsBatch /*2d*/, int numLayerInput, int numLayerOutput, int numSamples)
{
	int j = blockIdx.x * blockDim.x + threadIdx.x;
	int k = blockIdx.y * blockDim.y + threadIdx.y;

	if (j >= numLayerOutput || k >= numSamples)
		return;

	float sum = layerWeights[index2D(0, j, numLayerOutput)] * 1.0f; // bias
	for (int i = 0; i < numLayerInput; ++i)
	{
		sum += layerWeights[index2D((i + 1), j, numLayerOutput)] * layerInsBatch[index2D(k, i, numLayerInput)];
	}

	layerOutsBatch[index2D(k, j, numLayerOutput)] = layerActivationFunc(sum);
}

__global__ void computeErrorsOutsBatchKernel(float *errorsOutsBatch /*2d*/, const float *netOutsBatch /*2d*/,
	const float *targetOutsBatch /*2d*/, int numOutput, int numSamples)
{
	int j = blockIdx.x * blockDim.x + threadIdx.x;
	int k = blockIdx.y * blockDim.y + threadIdx.y;

	if (j >= numOutput || k >= numSamples)
		return;

	float error = (netOutsBatch[index2D(k, j, numOutput)] - targetOutsBatch[index2D(k, j, numOutput)]);

	errorsOutsBatch[index2D(k, j, numOutput)] = error * error;
}

__global__ void computeErrorKernel(float *error /* Single value */, const float *errorsOutsBatch /*2d*/,
	int numOutput, int numSamples)
{
	*error = 0.0f;
	for (int k = 0; k < numSamples; ++k)
	{
		for (int s = 0; s < numOutput; ++s)
		{
			*error += errorsOutsBatch[index2D(k, s, numOutput)];
		}
	}
}

__global__ void computeHOGradsBatchKernel(func_ptr outputFuncDerivative, float *hoGradsBatch /*3d*/,
	float *oDeltasBatch /*2d*/, const float *hOutsBatch /*2d*/, const float *netOutsBatch /*2d*/,
	const float *targetOutsBatch /*2d*/, int numHidden, int numOutput, int numSamples)
{
	int j = blockIdx.x * blockDim.x + threadIdx.x;
	int k = blockIdx.y * blockDim.y + threadIdx.y;

	if (j >= numOutput || k >= numSamples)
		return;

	float error = (netOutsBatch[index2D(k, j, numOutput)] - targetOutsBatch[index2D(k, j, numOutput)]);
	oDeltasBatch[index2D(k, j, numOutput)] = error * outputFuncDerivative(netOutsBatch[index2D(k, j, numOutput)]);

	hoGradsBatch[index3D(k, 0, j, (numHidden + 1), numOutput)] = oDeltasBatch[index2D(k, j, numOutput)] * 1.0f; // bias
	for (int i = 0; i < numHidden; ++i)
	{
		hoGradsBatch[index3D(k, (i + 1), j, (numHidden + 1), numOutput)] = oDeltasBatch[index2D(k, j, numOutput)] * hOutsBatch[index2D(k, i, numHidden)];
	}
}

__global__ void computeIHGradsBatchKernel(func_ptr hiddenFuncDerivative, float *ihGradsBatch /*3d*/,
	const float *hoWeights /*2d*/, const float *oDeltasBatch /*2d*/, float *hDeltasBatch /*2d*/,
	const float *hOutsBatch /*2d*/, const float *netInsBatch /*2d*/,
	int numInput, int numHidden, int numOutput, int numSamples)
{
	int i = blockIdx.x * blockDim.x + threadIdx.x;
	int k = blockIdx.y * blockDim.y + threadIdx.y;

	if (i >= (numInput + 1 /* bias */) || k >= numSamples)
		return;

	float input = ((k % numInput == 0) && (i == 0)) ? 1.0f : netInsBatch[index2D(k, i - 1, numInput)]; // bias?
	for (int j = 0; j < numHidden; ++j)
	{
		float sum = 0.0f;
		for (int s = 0; s < numOutput; ++s)
		{
			sum += oDeltasBatch[index2D(k, s, numOutput)] * hoWeights[index2D((j + 1), s, numOutput)];
		}

		hDeltasBatch[index2D(k, j, numHidden)] = sum * hiddenFuncDerivative(hOutsBatch[index2D(k, j, numHidden)]);
		ihGradsBatch[index3D(k, i, j, (numInput + 1), numHidden)] = hDeltasBatch[index2D(k, j, numHidden)] * input;
	}
}

__global__ void updateLayerWeightsBackPropKernel(float *layerGradsBatch /*3d*/, float *layerWeights /*2d*/,
	float *prevLayerWeightDeltas /*2d*/, float learningRate, float momentum,
	int numLayerInput, int numLayerOutput, int numSamples)
{
	int i = blockIdx.x * blockDim.x + threadIdx.x;
	int j = blockIdx.y * blockDim.y + threadIdx.y;

	if (i >= (numLayerInput + 1 /* bias */) || j >= numLayerOutput)
		return;

	float weightUpdatesSum = 0.0f;
	for (int k = 0; k < numSamples; ++k)
	{
		weightUpdatesSum += -learningRate * layerGradsBatch[index3D(k, i, j, (numLayerInput + 1), numLayerOutput)];
	}

	layerWeights[index2D(i, j, numLayerOutput)] += weightUpdatesSum;
	layerWeights[index2D(i, j, numLayerOutput)] += momentum * prevLayerWeightDeltas[index2D(i, j, numLayerOutput)];
	prevLayerWeightDeltas[index2D(i, j, numLayerOutput)] = weightUpdatesSum;
}

__global__ void updateLayerWeightsResilientPropKernel(const float *layerGradsBatch /*3d*/,
	float *prevLayerGradsBatch /*3d*/, float *layerWeights /*2d*/, float *layerLearningRatesBatch /*3d*/,
	int numLayerInput, int numLayerOutput, int numSamples)
{
	int i = blockIdx.x * blockDim.x + threadIdx.x;
	int j = blockIdx.y * blockDim.y + threadIdx.y;

	if (i >= (numLayerInput + 1 /* bias */) || j >= numLayerOutput)
		return;

	float weightUpdatesSum = 0.0f;
	for (int k = 0; k < numSamples; ++k)
	{
		float previousGradient = prevLayerGradsBatch[index3D(k, i, j, (numLayerInput + 1), numLayerOutput)];
		float currentGradient = layerGradsBatch[index3D(k, i, j, (numLayerInput + 1), numLayerOutput)];
		float change = previousGradient * currentGradient;

		if (change > 0.0f)
		{
			layerLearningRatesBatch[index3D(k, i, j, (numLayerInput + 1), numLayerOutput)] =
				fminf(A * layerLearningRatesBatch[index3D(k, i, j, (numLayerInput + 1), numLayerOutput)], MAX_LEARNING_RATE);
		}
		else if (change < 0.0f)
		{
			layerLearningRatesBatch[index3D(k, i, j, (numLayerInput + 1), numLayerOutput)] =
				fmaxf(B * layerLearningRatesBatch[index3D(k, i, j, (numLayerInput + 1), numLayerOutput)], MIN_LEARNING_RATE);
		}

		weightUpdatesSum += -layerLearningRatesBatch[index3D(k, i, j, (numLayerInput + 1), numLayerOutput)] * sign(currentGradient);
		prevLayerGradsBatch[index3D(k, i, j, (numLayerInput + 1), numLayerOutput)] = currentGradient;
	}

	layerWeights[index2D(i, j, numLayerOutput)] += weightUpdatesSum;
}

// Make randomly generated weights in (0.0, 1.0] be in the interval from -maxAbs to +maxAbs.
__global__ void normalizeLayerWeightsKernel(float *layerWeights /*2d*/, float maxAbs, int numLayerWeights)
{
	int i = blockIdx.x * blockDim.x + threadIdx.x;

	if (i >= numLayerWeights)
		return;

	layerWeights[i] = ((layerWeights[i] - 0.5f) / 0.5f) * maxAbs;
}

__global__ void fillArray(float *array, float value, int arrayLength)
{
	int i = blockIdx.x * blockDim.x + threadIdx.x;

	if (i >= arrayLength)
		return;

	array[i] = value;
}

int computeNumBlocks(int dataSize, int threadsPerBlock)
{
	int numBlocks = dataSize / threadsPerBlock;

	if (dataSize % threadsPerBlock)
		numBlocks++;

	return numBlocks;

	//return (dataSize + threadsPerBlock - 1) / threadsPerBlock;
}

dim3 getBlockDim1D()
{
	return dim3(16);
}

dim3 getBlockDim2D()
{
	return dim3(16, 16);
}

dim3 getGridDim1D(int dataSizeX, int threadsPerBlockX)
{
	return dim3(computeNumBlocks(dataSizeX, threadsPerBlockX));
}

dim3 getGridDim2D(int dataSizeX, int threadsPerBlockX, int dataSizeY, int threadsPerBlockY)
{
	return dim3(computeNumBlocks(dataSizeX, threadsPerBlockX), computeNumBlocks(dataSizeY, threadsPerBlockY));
}

void generateRandomFloatArrays(float *array1 /*2d*/, float *array2 /*2d*/, int array1Size, int array2Size)
{
	unsigned long long seed = (unsigned long long)time(NULL);

	curandGenerator_t gen;

	// Create and initialize generator
	curandCreateGenerator(&gen, CURAND_RNG_PSEUDO_XORWOW);
	curandSetPseudoRandomGeneratorSeed(gen, seed);
	curandSetGeneratorOrdering(gen, CURAND_ORDERING_PSEUDO_SEEDED);

	curandGenerateUniform(gen, array1, array1Size);
	curandGenerateUniform(gen, array2, array2Size);

	curandDestroyGenerator(gen);
}

void normalizeWeights(float *d_inputHiddenWeights /*2d*/, float *d_hiddenOutputWeights /*2d*/,
	int numInputHiddenWeights, int numHiddenOutputWeights)
{
	dim3 blockDim = getBlockDim1D();

	dim3 gridDim1 = getGridDim1D(numInputHiddenWeights, blockDim.x);
	normalizeLayerWeightsKernel<<<gridDim1, blockDim>>>(d_inputHiddenWeights, 0.5f, numInputHiddenWeights);

	dim3 gridDim2 = getGridDim1D(numHiddenOutputWeights, blockDim.x);
	normalizeLayerWeightsKernel<<<gridDim2, blockDim>>>(d_hiddenOutputWeights, 0.5f, numHiddenOutputWeights);
}

void randomizeWeights(CudaErrorPropagation *propagation)
{
	float *d_inputHiddenWeights = propagation->d_inputHiddenWeights;
	float *d_hiddenOutputWeights = propagation->d_hiddenOutputWeights;
	int numInputHiddenWeights = (propagation->numInput + 1) * propagation->numHidden;
	int numHiddenOutputWeights = (propagation->numHidden + 1) * propagation->numOutput;

	generateRandomFloatArrays(d_inputHiddenWeights, d_hiddenOutputWeights, numInputHiddenWeights, numHiddenOutputWeights);
	normalizeWeights(d_inputHiddenWeights, d_hiddenOutputWeights, numInputHiddenWeights, numHiddenOutputWeights);
}

void randomizeLearningRates(CudaErrorPropagation *propagation)
{
	float *d_inputHiddenLearningRatesBatch = propagation->d_inputHiddenLearningRatesBatch;
	float *d_hiddenOutputLearningRatesBatch = propagation->d_hiddenOutputLearningRatesBatch;
	int numInputHiddenLearningRatesBatch = propagation->numSamples * (propagation->numInput + 1) * propagation->numHidden;
	int numHiddenOutputLearningRatesBatch = propagation->numSamples * (propagation->numHidden + 1) * propagation->numOutput;

	generateRandomFloatArrays(d_inputHiddenLearningRatesBatch, d_hiddenOutputLearningRatesBatch,
		numInputHiddenLearningRatesBatch, numHiddenOutputLearningRatesBatch);
}

void fillLearningRates(CudaErrorPropagation *propagation, float value)
{
	float *d_inputHiddenLearningRatesBatch = propagation->d_inputHiddenLearningRatesBatch;
	float *d_hiddenOutputLearningRatesBatch = propagation->d_hiddenOutputLearningRatesBatch;
	int numInputHiddenLearningRatesBatch = propagation->numSamples * (propagation->numInput + 1) * propagation->numHidden;
	int numHiddenOutputLearningRatesBatch = propagation->numSamples * (propagation->numHidden + 1) * propagation->numOutput;

	dim3 blockDim = getBlockDim1D();

	dim3 gridDim1 = getGridDim1D(numInputHiddenLearningRatesBatch, blockDim.x);
	fillArray<<<gridDim1, blockDim>>>(d_inputHiddenLearningRatesBatch, value, numInputHiddenLearningRatesBatch);

	dim3 gridDim2 = getGridDim1D(numHiddenOutputLearningRatesBatch, blockDim.x);
	fillArray<<<gridDim2, blockDim>>>(d_hiddenOutputLearningRatesBatch, value, numHiddenOutputLearningRatesBatch);
}

void setLayerFunctionAndDerivative(func_ptr *function, func_ptr *derivative, ActivationFuncType type)
{
	switch (type)
	{
	case ActivationFuncType::UNIPOLAR_SIGMOID:
		cudaMemcpyFromSymbol(function, pUnipolarSigmoidFunction , sizeof(func_ptr));
		cudaMemcpyFromSymbol(derivative, pUnipolarSigmoidDerivative, sizeof(func_ptr));
		break;
	case ActivationFuncType::BIPOLAR_SIGMOID:
		cudaMemcpyFromSymbol(function, pBipolarSigmoidFunction, sizeof(func_ptr));
		cudaMemcpyFromSymbol(derivative, pBipolarSigmoidDerivative, sizeof(func_ptr));
		break;
	case ActivationFuncType::SINUSOID:
		cudaMemcpyFromSymbol(function, pSinusoidFunction, sizeof(func_ptr));
		cudaMemcpyFromSymbol(derivative, pSinusoidDerivative, sizeof(func_ptr));
		break;
	case ActivationFuncType::LINEAR:
		cudaMemcpyFromSymbol(function, pLinearFunction, sizeof(func_ptr));
		cudaMemcpyFromSymbol(derivative, pLinearDerivative, sizeof(func_ptr));
		break;
	default:
		cudaMemcpyFromSymbol(function, pUnipolarSigmoidFunction, sizeof(func_ptr));
		cudaMemcpyFromSymbol(derivative, pUnipolarSigmoidDerivative, sizeof(func_ptr));
		break;
	}
}

bool checkCudaSupport()
{
	int deviceCount, device;
	int gpuDeviceCount = 0;
	struct cudaDeviceProp properties;
	cudaError_t cudaResultCode = cudaGetDeviceCount(&deviceCount);
	if (cudaResultCode != cudaSuccess)
		deviceCount = 0;
	/* machines with no GPUs can still report one emulation device */
	for (device = 0; device < deviceCount; ++device)
	{
		cudaGetDeviceProperties(&properties, device);
		if (properties.major != 9999) /* 9999 means emulation only */
			++gpuDeviceCount;
	}

	/* don't just return the number of gpus, because other runtime cuda
	errors can also yield non-zero return values */
	if (gpuDeviceCount > 0)
		return true; /* success */
	else
		return false; /* failure */
}

CudaErrorPropagation* createErrorPropagation(float *h_inputData /*2d*/, float *h_outputData /*2d*/,
	float *h_inputHiddenWeights /*2d*/, float *h_hiddenOutputWeights /*2d*/,
	int numInput, int numHidden, int numOutput, int numSamples,
	ActivationFuncType hiddenFunc, ActivationFuncType outputFunc)
{
	CudaErrorPropagation *propagation = (CudaErrorPropagation *) malloc(sizeof(CudaErrorPropagation));

	// Initialize network and data params 
	propagation->numInput = numInput;
	propagation->numHidden = numHidden;
	propagation->numOutput = numOutput;
	propagation->numSamples = numSamples;

	cudaMalloc((void**) &(propagation->d_inputsBatch), numSamples * numInput * sizeof(float));
	cudaMalloc((void**) &(propagation->d_inputHiddenWeights), (numInput + 1) * numHidden * sizeof(float));
	cudaMalloc((void**) &(propagation->d_hiddenOutputsBatch), numSamples * numHidden * sizeof(float));
	cudaMalloc((void**) &(propagation->d_hiddenOutputWeights), (numHidden + 1) * numOutput * sizeof(float));
	cudaMalloc((void**) &(propagation->d_outputsBatch), numSamples * numOutput * sizeof(float));

	// Propagation
	cudaMalloc((void**) &(propagation->d_errorsOutputsBatch), numSamples * numOutput * sizeof(float));
	cudaMalloc((void**) &(propagation->d_error), sizeof(float));

	cudaMalloc((void**) &(propagation->d_targetOutputsBatch), numSamples * numOutput * sizeof(float));
	cudaMalloc((void**) &(propagation->d_outputDeltasBatch), numSamples * numOutput * sizeof(float));
	cudaMalloc((void**) &(propagation->d_hiddenDeltasBatch), numSamples * numHidden * sizeof(float));
	cudaMalloc((void**) &(propagation->d_hiddenOutputGradientsBatch), numSamples * (numHidden + 1) * numOutput * sizeof(float));
	cudaMalloc((void**) &(propagation->d_inputHiddenGradientsBatch), numSamples * (numInput + 1) * numHidden * sizeof(float));

	// BackPropagation
	cudaMalloc((void**) &(propagation->d_previousInputHiddenWeightDeltas), (numInput + 1) * numHidden * sizeof(float));
	cudaMalloc((void**) &(propagation->d_previousHiddenOutputWeightDeltas), (numHidden + 1) * numOutput * sizeof(float));

	// ResilientPropagation
	cudaMalloc((void**) &(propagation->d_previousInputHiddenGradientsBatch), numSamples * (numInput + 1) * numHidden * sizeof(float));
	cudaMalloc((void**) &(propagation->d_previousHiddenOutputGradientsBatch), numSamples * (numHidden + 1) * numOutput * sizeof(float));
	cudaMalloc((void**) &(propagation->d_inputHiddenLearningRatesBatch), numSamples * (numInput + 1) * numHidden * sizeof(float));
	cudaMalloc((void**) &(propagation->d_hiddenOutputLearningRatesBatch), numSamples * (numHidden + 1) * numOutput * sizeof(float));

	// Computed weights
	propagation->h_inputHiddenWeights = (float *) malloc((numInput + 1) * numHidden * sizeof(float));
	propagation->h_hiddenOutputWeights = (float *) malloc((numHidden + 1) * numOutput * sizeof(float));

	// Copy initial network weights
	memcpy(propagation->h_inputHiddenWeights, h_inputHiddenWeights, (numInput + 1) * numHidden * sizeof(float));
	memcpy(propagation->h_hiddenOutputWeights, h_hiddenOutputWeights, (numHidden + 1) * numOutput * sizeof(float));
	cudaMemcpy(propagation->d_inputHiddenWeights, propagation->h_inputHiddenWeights,
		(propagation->numInput + 1) * propagation->numHidden * sizeof(float), cudaMemcpyKind::cudaMemcpyHostToDevice);
	cudaMemcpy(propagation->d_hiddenOutputWeights, propagation->h_hiddenOutputWeights,
		(propagation->numHidden + 1) * propagation->numOutput * sizeof(float), cudaMemcpyKind::cudaMemcpyHostToDevice);

	// Copy input and output learning data
	cudaMemcpy(propagation->d_inputsBatch, h_inputData, numSamples * numInput * sizeof(float), cudaMemcpyKind::cudaMemcpyHostToDevice);
	cudaMemcpy(propagation->d_targetOutputsBatch, h_outputData, numSamples * numOutput * sizeof(float), cudaMemcpyKind::cudaMemcpyHostToDevice);

	// Reset previous params to 0
	cudaMemset(propagation->d_previousInputHiddenWeightDeltas, 0, (numInput + 1) * numHidden * sizeof(float));
	cudaMemset(propagation->d_previousHiddenOutputWeightDeltas, 0, (numHidden + 1) * numOutput * sizeof(float));
	cudaMemset(propagation->d_previousInputHiddenGradientsBatch, 0, numSamples * (numInput + 1) * numHidden * sizeof(float));
	cudaMemset(propagation->d_previousHiddenOutputGradientsBatch, 0, numSamples * (numHidden + 1) * numOutput * sizeof(float));

	//randomizeLearningRates(propagation);
	fillLearningRates(propagation, MIN_LEARNING_RATE);

	// Set layers activation functions and derivatives
	setLayerFunctionAndDerivative(&(propagation->h_pHiddenFunction), &(propagation->h_pHiddenDerivative), hiddenFunc);
	setLayerFunctionAndDerivative(&(propagation->h_pOutputFunction), &(propagation->h_pOutputDerivative), outputFunc);
	
	return propagation;
}

void destroyErrorPropagation(CudaErrorPropagation *propagation)
{
	if (!propagation)
		return;
	// Network and data
	cudaFree(propagation->d_inputsBatch);
	cudaFree(propagation->d_inputHiddenWeights);
	cudaFree(propagation->d_hiddenOutputsBatch);
	cudaFree(propagation->d_hiddenOutputWeights);
	cudaFree(propagation->d_outputsBatch);

	// Propagation
	cudaFree(propagation->d_errorsOutputsBatch);
	cudaFree(propagation->d_error);

	cudaFree(propagation->d_targetOutputsBatch);
	cudaFree(propagation->d_outputDeltasBatch);
	cudaFree(propagation->d_hiddenDeltasBatch);
	cudaFree(propagation->d_hiddenOutputGradientsBatch);
	cudaFree(propagation->d_inputHiddenGradientsBatch);

	// BackPropagation
	cudaFree(propagation->d_previousInputHiddenWeightDeltas);
	cudaFree(propagation->d_previousHiddenOutputWeightDeltas);

	// ResilientPropagation
	cudaFree(propagation->d_previousInputHiddenGradientsBatch);
	cudaFree(propagation->d_previousHiddenOutputGradientsBatch);
	cudaFree(propagation->d_inputHiddenLearningRatesBatch);
	cudaFree(propagation->d_hiddenOutputLearningRatesBatch);

	// Computed weights
	free(propagation->h_inputHiddenWeights);
	free(propagation->h_hiddenOutputWeights);

	free(propagation);
}

const float* getInputHiddenWeights(CudaErrorPropagation *propagation)
{
	cudaMemcpy(propagation->h_inputHiddenWeights, propagation->d_inputHiddenWeights,
		(propagation->numInput + 1) * propagation->numHidden * sizeof(float), cudaMemcpyKind::cudaMemcpyDeviceToHost);

	return propagation->h_inputHiddenWeights;
}

const float* getHiddenOutputWeights(CudaErrorPropagation *propagation)
{
	cudaMemcpy(propagation->h_hiddenOutputWeights, propagation->d_hiddenOutputWeights,
		(propagation->numHidden + 1) * propagation->numOutput * sizeof(float), cudaMemcpyKind::cudaMemcpyDeviceToHost);

	return propagation->h_hiddenOutputWeights;
}

void computeOutputBatch(CudaErrorPropagation *propagation)
{
	dim3 blockDim = getBlockDim2D();

	dim3 gridDim1 = getGridDim2D(propagation->numHidden, blockDim.x, propagation->numSamples, blockDim.y);	
	computeLayerOutputBatchKernel<<<gridDim1, blockDim>>>(propagation->h_pHiddenFunction, propagation->d_inputsBatch,
		propagation->d_inputHiddenWeights, propagation->d_hiddenOutputsBatch,
		propagation->numInput, propagation->numHidden, propagation->numSamples);

	dim3 gridDim2 = getGridDim2D(propagation->numOutput, blockDim.x, propagation->numSamples, blockDim.y);	
	computeLayerOutputBatchKernel<<<gridDim2, blockDim>>>(propagation->h_pOutputFunction, propagation->d_hiddenOutputsBatch,
		propagation->d_hiddenOutputWeights, propagation->d_outputsBatch,
		propagation->numHidden, propagation->numOutput, propagation->numSamples);
}

float computeError(CudaErrorPropagation *propagation)
{
	computeOutputBatch(propagation);

	dim3 blockDim = getBlockDim2D();
	dim3 gridDim1 = getGridDim2D(propagation->numOutput, blockDim.x, propagation->numSamples, blockDim.y);
	computeErrorsOutsBatchKernel<<<gridDim1, blockDim>>>(propagation->d_errorsOutputsBatch, propagation->d_outputsBatch,
		propagation->d_targetOutputsBatch, propagation->numOutput, propagation->numSamples);

	computeErrorKernel<<<1, 1>>>(propagation->d_error, propagation->d_errorsOutputsBatch,
		propagation->numOutput, propagation->numSamples);

	float h_error = FLT_MAX;
	cudaError_t status = cudaMemcpy(&h_error, propagation->d_error, sizeof(float), cudaMemcpyKind::cudaMemcpyDeviceToHost);

	if (status != cudaError::cudaSuccess)
		return 1.0f;

	//return 0.5f * h_error;
	return sqrtf((1.0f / propagation->numSamples) * (1.0f / propagation->numOutput) * h_error);
}

void computeGradientsBatch(CudaErrorPropagation *propagation)
{
	dim3 blockDim = getBlockDim2D();

	dim3 gridDim1 = getGridDim2D(propagation->numOutput, blockDim.x, propagation->numSamples, blockDim.y);
	computeHOGradsBatchKernel<<<gridDim1, blockDim>>>(propagation->h_pOutputDerivative, propagation->d_hiddenOutputGradientsBatch,
		propagation->d_outputDeltasBatch, propagation->d_hiddenOutputsBatch, propagation->d_outputsBatch,
		propagation->d_targetOutputsBatch, propagation->numHidden, propagation->numOutput, propagation->numSamples);

	dim3 gridDim2 = getGridDim2D(propagation->numInput + 1 /* bias */, blockDim.x, propagation->numSamples, blockDim.y);
	computeIHGradsBatchKernel<<<gridDim2, blockDim>>>(propagation->h_pHiddenDerivative, propagation->d_inputHiddenGradientsBatch,
		propagation->d_hiddenOutputWeights, propagation->d_outputDeltasBatch, propagation->d_hiddenDeltasBatch,
		propagation->d_hiddenOutputsBatch, propagation->d_inputsBatch, propagation->numInput, propagation->numHidden,
		propagation->numOutput, propagation->numSamples);
}

void updateWeightsBackProp(CudaErrorPropagation *propagation, float learningRate, float momentum)
{
	dim3 blockDim = getBlockDim2D();

	dim3 gridDim1 = getGridDim2D(propagation->numInput + 1 /* bias */, blockDim.x, propagation->numHidden, blockDim.y);
	updateLayerWeightsBackPropKernel<<<gridDim1, blockDim>>>(propagation->d_inputHiddenGradientsBatch,
		propagation->d_inputHiddenWeights, propagation->d_previousInputHiddenWeightDeltas, learningRate,
		momentum, propagation->numInput, propagation->numHidden, propagation->numSamples);

	dim3 gridDim2 = getGridDim2D(propagation->numHidden + 1 /* bias */, blockDim.x, propagation->numOutput, blockDim.y);
	updateLayerWeightsBackPropKernel<<<gridDim2, blockDim>>>(propagation->d_hiddenOutputGradientsBatch,
		propagation->d_hiddenOutputWeights, propagation->d_previousHiddenOutputWeightDeltas, learningRate,
		momentum, propagation->numHidden, propagation->numOutput, propagation->numSamples);
}

void updateWeightsResilientProp(CudaErrorPropagation *propagation)
{
	dim3 blockDim = getBlockDim2D();

	dim3 gridDim1 = getGridDim2D(propagation->numInput + 1 /* bias */, blockDim.x, propagation->numHidden, blockDim.y);
	updateLayerWeightsResilientPropKernel<<<gridDim1, blockDim>>>(propagation->d_inputHiddenGradientsBatch,
		propagation->d_previousInputHiddenGradientsBatch, propagation->d_inputHiddenWeights, propagation->d_inputHiddenLearningRatesBatch,
		propagation->numInput, propagation->numHidden, propagation->numSamples);

	dim3 gridDim2 = getGridDim2D(propagation->numHidden + 1 /* bias */, blockDim.x, propagation->numOutput, blockDim.y);
	updateLayerWeightsResilientPropKernel<<<gridDim2, blockDim>>>(propagation->d_hiddenOutputGradientsBatch,
		propagation->d_previousHiddenOutputGradientsBatch, propagation->d_hiddenOutputWeights, propagation->d_hiddenOutputLearningRatesBatch,
		propagation->numHidden, propagation->numOutput, propagation->numSamples);
}

float performBackPropEpoch(CudaErrorPropagation *propagation, float learningRate, float momentum)
{
	computeOutputBatch(propagation);
	computeGradientsBatch(propagation);
	updateWeightsBackProp(propagation, learningRate, momentum);

	return computeError(propagation);
}

float performResilientPropEpoch(CudaErrorPropagation *propagation)
{
	computeOutputBatch(propagation);
	computeGradientsBatch(propagation);
	updateWeightsResilientProp(propagation);

	return computeError(propagation);
}