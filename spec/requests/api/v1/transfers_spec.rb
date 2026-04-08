# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'API V1 Transfers', type: :request do
  let(:family) do
    Family.create!(
      name: 'API Family',
      currency: 'USD',
      locale: 'en',
      date_format: '%m-%d-%Y'
    )
  end

  let(:user) do
    family.users.create!(
      email: 'api-transfers@example.com',
      password: 'password123',
      password_confirmation: 'password123'
    )
  end

  let(:api_key) do
    key = ApiKey.generate_secure_key
    ApiKey.create!(
      user: user,
      name: 'API Docs Key',
      key: key,
      scopes: %w[read_write],
      source: 'web'
    )
  end

  let(:'X-Api-Key') { api_key.plain_key }

  let!(:from_account) do
    family.accounts.create!(
      name: 'Checking Account',
      balance: 5000,
      currency: 'USD',
      accountable: Depository.new
    )
  end

  let!(:to_account) do
    family.accounts.create!(
      name: 'Savings Account',
      balance: 2000,
      currency: 'USD',
      accountable: Depository.new
    )
  end

  let!(:existing_transfer) do
    Transfer::Creator.new(
      family: family,
      source_account_id: from_account.id,
      destination_account_id: to_account.id,
      date: Date.current,
      amount: 500
    ).create
  end

  path '/api/v1/transfers' do
    get 'List transfers' do
      tags 'Transfers'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      parameter name: :page, in: :query, type: :integer, required: false, description: 'Page number (default: 1)'
      parameter name: :per_page, in: :query, type: :integer, required: false, description: 'Items per page (default: 25, max: 100)'
      parameter name: :account_id, in: :query, type: :string, required: false, description: 'Filter by account ID (either side)'
      parameter name: :start_date, in: :query, type: :string, format: :date, required: false, description: 'Filter by start date'
      parameter name: :end_date, in: :query, type: :string, format: :date, required: false, description: 'Filter by end date'

      response '200', 'transfers listed' do
        schema '$ref' => '#/components/schemas/TransferCollection'

        run_test!
      end
    end

    post 'Create transfer' do
      tags 'Transfers'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json'
      produces 'application/json'
      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        properties: {
          transfer: {
            type: :object,
            properties: {
              from_account_id: { type: :string, format: :uuid, description: 'Source account ID' },
              to_account_id: { type: :string, format: :uuid, description: 'Destination account ID' },
              amount: { type: :number, description: 'Transfer amount (positive)' },
              date: { type: :string, format: :date, description: 'Transfer date (YYYY-MM-DD)' }
            },
            required: %w[from_account_id to_account_id amount date]
          }
        },
        required: %w[transfer]
      }

      response '201', 'transfer created' do
        schema '$ref' => '#/components/schemas/TransferDetail'

        let(:body) do
          {
            transfer: {
              from_account_id: from_account.id,
              to_account_id: to_account.id,
              amount: 100.00,
              date: Date.current.iso8601
            }
          }
        end

        run_test!
      end

      response '422', 'validation error - missing fields' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:body) do
          {
            transfer: {
              from_account_id: from_account.id
            }
          }
        end

        run_test!
      end
    end
  end

  path '/api/v1/transfers/{id}' do
    parameter name: :id, in: :path, type: :string, required: true, description: 'Transfer ID'

    get 'Retrieve a transfer' do
      tags 'Transfers'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      let(:id) { existing_transfer.id }

      response '200', 'transfer retrieved' do
        schema '$ref' => '#/components/schemas/TransferDetail'

        run_test!
      end

      response '404', 'transfer not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { SecureRandom.uuid }

        run_test!
      end
    end

    patch 'Update a transfer' do
      tags 'Transfers'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json'
      produces 'application/json'

      let(:id) { existing_transfer.id }

      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        properties: {
          transfer: {
            type: :object,
            properties: {
              status: { type: :string, enum: %w[confirmed rejected], description: 'Update transfer status' },
              notes: { type: :string, description: 'Transfer notes' },
              category_id: { type: :string, format: :uuid, description: 'Category ID (only for loan payments)' }
            }
          }
        }
      }

      response '200', 'transfer updated' do
        schema '$ref' => '#/components/schemas/TransferDetail'

        let(:body) do
          {
            transfer: {
              notes: 'Monthly savings contribution'
            }
          }
        end

        run_test!
      end

      response '404', 'transfer not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { SecureRandom.uuid }

        let(:body) do
          {
            transfer: {
              notes: 'test'
            }
          }
        end

        run_test!
      end
    end

    delete 'Delete a transfer' do
      tags 'Transfers'
      security [ { apiKeyAuth: [] } ]

      let(:id) { existing_transfer.id }

      response '200', 'transfer deleted' do
        schema '$ref' => '#/components/schemas/DeleteResponse'

        run_test!
      end

      response '404', 'transfer not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { SecureRandom.uuid }

        run_test!
      end
    end
  end
end
