#include "stdafx.h"
#include "networkdataset.h"
#include "matrixhelper.h"

namespace mlp_network
{
	// ������ ������ ����� ����� ������ ��� ����.
	NetworkDataset::NetworkDataset() : size_(0), inputSize_(0), outputSize_(0)
	{
	}

	// ������ ����� ����� ������ ��� ����, ��������� ������� ������� � �������� ������.
	NetworkDataset::NetworkDataset(const matrix<double> &inputData, const matrix<double> &outputData)
		: size_(inputData.size()), inputSize_(inputData[0].size()), outputSize_(outputData[0].size()),
		inputData_(inputData), outputData_(outputData)
	{
	}

	// ������ ����� ����� ������ ��� ����, ��������� ������ ������ ������, � ����� ������� ������� � �������� ������� ������.
	NetworkDataset::NetworkDataset(size_t size, size_t inputSize, size_t outputSize)
		: size_(size), inputSize_(inputSize), outputSize_(outputSize),
		inputData_(MatrixHelper::createMatrix<double>(size, inputSize)),
		outputData_(MatrixHelper::createMatrix<double>(size, outputSize))
	{	
	}

	// ���������� ������ ������ ������ ��� ����.
	size_t NetworkDataset::size() const
	{
		return size_;
	}

	// ���������� ������� ������� ������ ����.
	const matrix<double>& NetworkDataset::inputData() const
	{
		return inputData_;
	}

	// ����� ������� ������� ������ ����.
	void NetworkDataset::setInputData(const matrix<double> &inputData)
	{
		inputData_ = inputData;
	}

	// ���������� ������� �������� ������ ����.
	const matrix<double>& NetworkDataset::outputData() const
	{
		return outputData_;
	}

	// ����� ������� �������� ������ ����.
	void NetworkDataset::setOutputData(const matrix<double> &outputData)
	{
		outputData_ = outputData;
	}
}
