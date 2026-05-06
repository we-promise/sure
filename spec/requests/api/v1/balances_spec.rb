# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'API V1 Balances', type: :request do
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
      scopes: %w[write],
      source: 'web'
    ).tap { |api_key| api_key.save!(validate: false) }
  end

  let(:'X-Api-Key') { api_key.plain_key }

  let!(:account) do
    Account.create!(
      family: family,
      name: 'Checking Account',
      balance: 1500.50,
      currency: 'USD',
      accountable: Depository.create!
    )
  end

  let!(:balance) do
    account.balances.create!(
      date: Date.parse('2024-01-15'),
      balance: 1500.50,
      cash_balance: 1500.50,
      start_cash_balance: 1200,
      start_non_cash_balance: 0,
      cash_inflows: 300.50,
      cash_outflows: 0,
      currency: 'USD'
    )
  end

  path '/api/v1/balances' do
    get 'List balance history records' do
      tags 'Balances'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'
      parameter name: :page, in: :query, type: :integer, required: false,
                description: 'Page number (default: 1)'
      parameter name: :per_page, in: :query, type: :integer, required: false,
                description: 'Items per page (default: 25, max: 100)'
      parameter name: :account_id, in: :query, required: false,
                description: 'Filter by account ID',
                schema: { type: :string, format: :uuid }
      parameter name: :currency, in: :query, required: false,
                description: 'Filter by currency code',
                schema: { type: :string }
      parameter name: :start_date, in: :query, required: false,
                description: 'Filter balances from this date',
                schema: { type: :string, format: :date }
      parameter name: :end_date, in: :query, required: false,
                description: 'Filter balances until this date',
                schema: { type: :string, format: :date }

      response '200', 'balances listed' do
        schema '$ref' => '#/components/schemas/BalanceCollection'

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

        let(:account_id) { 'not-a-uuid' }

        run_test!
      end
    end
  end

  path '/api/v1/balances/{id}' do
    parameter name: :id, in: :path, required: true, description: 'Balance ID',
              schema: { type: :string, format: :uuid }

    get 'Retrieve a balance history record' do
      tags 'Balances'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      let(:id) { balance.id }

      response '200', 'balance retrieved' do
        schema '$ref' => '#/components/schemas/Balance'

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

      response '404', 'balance not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { SecureRandom.uuid }

        run_test!
      end
    end
  end
end
