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
      email: 'api-user@example.com',
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

  let(:api_key_without_read_scope) do
    key = ApiKey.generate_secure_key
    ApiKey.new(
      user: user,
      name: 'No Read Docs Key',
      key: key,
      scopes: [],
      source: 'mobile'
    ).tap { |api_key| api_key.save!(validate: false) }
  end

  let(:'X-Api-Key') { api_key.plain_key }
  let(:checking) { family.accounts.create!(name: 'Checking', balance: 1000, currency: 'USD', accountable: Depository.create!) }
  let(:savings) { family.accounts.create!(name: 'Savings', balance: 2500, currency: 'USD', accountable: Depository.create!) }
  let!(:outflow_entry) do
    checking.entries.create!(
      date: Date.current,
      amount: 100,
      name: 'Transfer to savings',
      currency: 'USD',
      entryable: Transaction.new(kind: 'funds_movement')
    )
  end
  let!(:inflow_entry) do
    savings.entries.create!(
      date: Date.current,
      amount: -100,
      name: 'Transfer from checking',
      currency: 'USD',
      entryable: Transaction.new(kind: 'funds_movement')
    )
  end
  let!(:transfer) do
    Transfer.create!(
      outflow_transaction: outflow_entry.entryable,
      inflow_transaction: inflow_entry.entryable,
      status: 'confirmed',
      notes: 'Confirmed by user'
    )
  end

  path '/api/v1/transfers' do
    get 'List transfers' do
      tags 'Transfers'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'
      parameter name: :page, in: :query, type: :integer, required: false,
                description: 'Page number (default: 1)'
      parameter name: :per_page, in: :query, type: :integer, required: false,
                description: 'Items per page (default: 25, max: 100)'
      parameter name: :status, in: :query, required: false,
                schema: { type: :string, enum: %w[pending confirmed] },
                description: 'Filter by transfer status'
      parameter name: :account_id, in: :query, required: false,
                schema: { type: :string, format: :uuid },
                description: 'Filter transfers involving this account'
      parameter name: :start_date, in: :query, required: false,
                schema: { type: :string, format: :date },
                description: 'Filter transfers from this date'
      parameter name: :end_date, in: :query, required: false,
                schema: { type: :string, format: :date },
                description: 'Filter transfers until this date'

      response '200', 'transfers listed' do
        schema '$ref' => '#/components/schemas/TransferDecisionCollection'

        run_test!
      end

      response '401', 'unauthorized' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { nil }

        run_test!
      end

      response '403', 'insufficient scope' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { api_key_without_read_scope.plain_key }

        run_test!
      end

      response '422', 'invalid filter' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:status) { 'settled' }

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

      let(:id) { transfer.id }

      response '200', 'transfer retrieved' do
        schema '$ref' => '#/components/schemas/TransferDecision'

        run_test!
      end

      response '401', 'unauthorized' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { nil }

        run_test!
      end

      response '403', 'insufficient scope' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { api_key_without_read_scope.plain_key }

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
