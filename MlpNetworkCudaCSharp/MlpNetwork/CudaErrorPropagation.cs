﻿using System;
using System.Runtime.InteropServices;

namespace MlpNetwork
{
    public enum ErrorPropagationType
    {
        BackPropagation = 0,
        ResilientPropagation = 1
    }

    public class CudaErrorPropagation : IDisposable
    {
        private MlpNetwork network;
        private NetworkDataSet dataSet;

        private IntPtr propagationHandle = IntPtr.Zero;
        private bool disposed = false;

        public CudaErrorPropagation(MlpNetwork network, NetworkDataSet dataSet)
        {
            this.network = network;
            this.dataSet = dataSet;

            float[] inputDataFlatten = Convert2DArrayTo1D(dataSet.GetInputData());
            float[] outputDataFlatten = Convert2DArrayTo1D(dataSet.GetOutputData());
            float[] inputHiddenWeightsFlatten = Convert2DArrayTo1D(network.GetInputHiddenWeights());
            float[] hiddenOutputWeightsFlatten = Convert2DArrayTo1D(network.GetHiddenOutputWeights());

            propagationHandle = NativeMethods.CreateErrorPropagation(inputDataFlatten, outputDataFlatten,
                inputHiddenWeightsFlatten, hiddenOutputWeightsFlatten,
                network.NumInput, network.NumHidden, network.NumOutput, dataSet.NumSamples,
                network.HiddenFunctionType, network.OutputFunctionType);
        }

        public void RandomizeNetworkWeights()
        {
            NativeMethods.RandomizeWeights(propagationHandle);
        }

        public float PerformBackPropEpoch(float learningRate, float momentum)
        {
            return NativeMethods.PerformBackPropEpoch(propagationHandle, learningRate, momentum);
        }

        public float PerformResilientPropEpoch()
        {
            return NativeMethods.PerformResilientPropEpoch(propagationHandle);
        }

        public void UpdateNetworkWeights()
        {
            IntPtr ihWeightsFlattenPtr = this.GetInputHiddenWeightsPtr();
            IntPtr hoWeightsFlattenPtr = this.GetHiddenOutputWeightsPtr();

            int ihWeightsX = network.NumInput + 1;
            int ihWeightsY = network.NumHidden;
            int hoWeightsX = network.NumHidden + 1;
            int hoWeightsY = network.NumOutput;

            int ihWeightsXY = ihWeightsX * ihWeightsY;
            int hoWeightsXY = hoWeightsX * hoWeightsY;

            float[] ihWeightsFlatten = new float[ihWeightsXY];
            float[] hoWeightsFlatten = new float[hoWeightsXY];
            Marshal.Copy(ihWeightsFlattenPtr, ihWeightsFlatten, 0, ihWeightsFlatten.Length);
            Marshal.Copy(hoWeightsFlattenPtr, hoWeightsFlatten, 0, hoWeightsFlatten.Length);
            float[][] ihWeights = Convert1DArrayTo2D(ihWeightsFlatten, ihWeightsX,
                ihWeightsY);
            float[][] hoWeights = Convert1DArrayTo2D(hoWeightsFlatten, hoWeightsX,
                hoWeightsY);

            network.SetInputHiddenWeights(ihWeights);
            network.SetHiddenOutputWeights(hoWeights);
        }

        public void Dispose()
        {
            Dispose(true);
            GC.SuppressFinalize(this);
        }

        protected virtual void Dispose(bool disposing)
        {
            if(!disposed)
            {
                if(disposing)
                {
                    // Dispose managed resources.
                }

                NativeMethods.DestroyErrorPropagation(propagationHandle);
                propagationHandle = IntPtr.Zero;

                disposed = true;
            }
        }

        private IntPtr GetInputHiddenWeightsPtr()
        {
            return NativeMethods.GetInputHiddenWeights(propagationHandle);
        }

        private IntPtr GetHiddenOutputWeightsPtr()
        {
            return NativeMethods.GetHiddenOutputWeights(propagationHandle);
        }

        private static long Get1DIndexFrom2D(int i, int j, int width)
        {
            return i * width + j;
        }

        private static T[] Convert2DArrayTo1D<T>(T[][] array2D)
        {
            T[] array1D = new T[array2D.Length * array2D[0].Length];
            for (int i = 0; i < array2D.Length; i++)
            {
                for (int j = 0; j < array2D[i].Length; j++)
                {
                    array1D[Get1DIndexFrom2D(i, j, array2D[i].Length)] = array2D[i][j];
                }
            }

            return array1D;
        }

        private static T[][] Convert1DArrayTo2D<T>(T[] array1D, int xLength, int yLength)
        {
            T[][] array2D = new T[xLength][];
            for (int i = 0; i < array2D.Length; i++)
            {
                array2D[i] = new T[yLength];
                for (int j = 0; j < array2D[i].Length; j++)
                {
                    array2D[i][j] = array1D[Get1DIndexFrom2D(i, j, array2D[i].Length)];
                }
            }

            return array2D;
        }

        ~CudaErrorPropagation()
        {
            Dispose(false);
        }
    }
}
