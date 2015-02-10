#include "stdafx.h"
#include "mlpnetwork.h"
#include "matrixhelper.h"

namespace mlp_network
{
	// ������ ����� ��������� ������������� �����������.
	MlpNetwork::MlpNetwork(size_t numInput, size_t numHidden, size_t numOutput,
		const ActivationFunction &hiddenFunction, const ActivationFunction &outputFunction)
		: numInput_(numInput), numHidden_(numHidden), numOutput_(numOutput),
		hiddenFunction_(hiddenFunction), outputFunction_(outputFunction),
		inputs_(numInput),
		inputHiddenWeights_(MatrixHelper::createMatrix<double>(numInput, numHidden)),
		hiddenOutputs_(numHidden + 1),
		hiddenOutputWeights_(MatrixHelper::createMatrix<double>(numHidden + 1, numOutput)),
		outputs_(numOutput)
	{
	}

	// ���������� ����� ������ ���� (� ������ ���������� �������).
	size_t MlpNetwork::numInput() const
	{
		return numInput_;
	}

	// ���������� ����� �������� � ������� ���� ���� (��� ����� ���������� �������).
	size_t MlpNetwork::numHidden() const
	{
		return numHidden_;
	}

	// ���������� ����� �������� � �������� ���� ����.
	size_t MlpNetwork::numOutput() const
	{
		return numOutput_;
	}

	// ���������� ��� ������� ��������� �������� �������� ���� ����.
	const ActivationFunction& MlpNetwork::hiddenFunction() const
	{
		return hiddenFunction_;
	}

	// ����� ��� ������� ��������� �������� �������� ���� ����.
	void MlpNetwork::setHiddenFunction(const ActivationFunction &hiddenFunction)
	{
		hiddenFunction_ = hiddenFunction;
	}

	// ���������� ��� ������� ��������� �������� ��������� ���� ����.
	const ActivationFunction& MlpNetwork::outputFunction() const
	{
		return outputFunction_;
	}

	// ����� ��� ������� ��������� �������� ��������� ���� ����.
	void MlpNetwork::setOutputFunction(const ActivationFunction &outputFunction)
	{
		outputFunction_ = outputFunction;
	}

	// ���������� �������� ������ ����.
	const vector<double>& MlpNetwork::inputs() const
	{
		return inputs_;
	}

	// ����� �������� ������ ����.
	void MlpNetwork::setInputs(const vector<double> &inputs)
	{
		inputs_ = inputs;
	}

	// ���������� ������� ����� ��������-�������� ���� ����.
	const matrix<double>& MlpNetwork::inputHiddenWeights() const
	{
		return inputHiddenWeights_;
	}

	// ����� ������� ����� ��������-�������� ���� ����.
	void MlpNetwork::setInputHiddenWeights(const matrix<double> &inputHiddenWeights)
	{
		inputHiddenWeights_ = inputHiddenWeights;
	}

	// ���������� �������� ������� �������� ���� ����.
	const vector<double>& MlpNetwork::hiddenOutputs() const
	{
		return hiddenOutputs_;
	}

	// ���������� ������� ����� ��������-��������� ���� ����.
	const matrix<double>& MlpNetwork::hiddenOutputWeights() const
	{
		return hiddenOutputWeights_;
	}

	// ����� ������� ����� ��������-��������� ���� ����.
	void MlpNetwork::setHiddenOutputWeights(const matrix<double> &hiddenOutputWeights)
	{
		hiddenOutputWeights_ = hiddenOutputWeights;
	}

	// ���������� �������� ������� ����.
	const vector<double>& MlpNetwork::outputs() const
	{
		return outputs_;
	}

	// ������������ �������� ������� ����.
	void MlpNetwork::computeOutputs()
	{
		computeHiddenSignal();
		computeOutputSignal();
	}

	// ������������ � ���������� ������ �������� ������� ���� ��� �������� �������� ������.
	const vector<double>& MlpNetwork::computeOutputs(const vector<double> &inputs)
	{
		inputs_ = inputs;

		computeOutputs();

		return outputs_;
	}

	// ������������ � ���������� ������� �������� ������� ���� ��� �������� �������� ������.
	matrix<double> MlpNetwork::computeOutputs(const matrix<double> &inputData)
	{
		matrix<double> matrix = MatrixHelper::createMatrix<double>(inputData.size(), inputData[0].size());
		for (size_t t = 0; t < inputData.size(); ++t)
		{
			matrix[t] =	computeOutputs(inputData[t]);
		}

		return matrix;
	}

	// ������������ �������� ������� �������� ���� ����.
	void MlpNetwork::computeHiddenSignal()
	{
		hiddenOutputs_[0] = 1;
		for (size_t i = 1; i < numHidden_ + 1; ++i)
		{
			double sum = 0;
			for (size_t j = 0; j < numInput_; ++j)
			{
				sum += inputHiddenWeights_[j][i - 1] * inputs_[j];
			}

			hiddenOutputs_[i] = hiddenFunction_.value(sum);
		}
	}

	// ������������ �������� ������� ��������� ���� ����.
	void MlpNetwork::computeOutputSignal()
	{
		for (size_t s = 0; s < numOutput_; ++s)
		{
			double sum = 0;
			for (size_t i = 0; i < numHidden_ + 1; ++i)
			{
				sum += hiddenOutputWeights_[i][s] * hiddenOutputs_[i];
			}

			outputs_[s] = outputFunction_.value(sum);
		}
	}
}
