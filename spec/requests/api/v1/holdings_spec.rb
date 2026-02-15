# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'API V1 Holdings', type: :request do
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

  let(:'X-Api-Key') { api_key.plain_key }

  let(:account) do
    Account.create!(
      family: family,
      name: 'Investment Account',
      balance: 50_000,
      currency: 'USD',
      accountable: Investment.create!
    )
  end

  let(:security) do
    Security.create!(
      ticker: 'VTI',
      name: 'Vanguard Total Stock Market ETF',
      country_code: 'US'
    )
  end

  let!(:holding) do
    Holding.create!(
      account: account,
      security: security,
      date: Date.current,
      qty: 100,
      price: 250.50,
      amount: 25_050,
      currency: 'USD'
    )
  end

  path '/api/v1/holdings' do
    get 'List holdings' do
      tags 'Holdings'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'
      parameter name: :page, in: :query, type: :integer, required: false,
                description: 'Page number (default: 1)'
      parameter name: :per_page, in: :query, type: :integer, required: false,
                description: 'Items per page (default: 25, max: 100)'
      parameter name: :account_id, in: :query, type: :string, required: false,
                description: 'Filter by account ID'
      parameter name: :account_ids, in: :query, required: false,
                description: 'Filter by multiple account IDs',
                schema: { type: :array, items: { type: :string } }
      parameter name: :date, in: :query, required: false,
                description: 'Filter by exact date',
                schema: { type: :string, format: :date }
      parameter name: :start_date, in: :query, required: false,
                description: 'Filter holdings from this date (inclusive)',
                schema: { type: :string, format: :date }
      parameter name: :end_date, in: :query, required: false,
                description: 'Filter holdings until this date (inclusive)',
                schema: { type: :string, format: :date }
      parameter name: :security_id, in: :query, type: :string, required: false,
                description: 'Filter by security ID'

      response '200', 'holdings listed' do
        schema '$ref' => '#/components/schemas/HoldingCollection'

        run_test!
      end

      response '200', 'holdings filtered by account' do
        schema '$ref' => '#/components/schemas/HoldingCollection'

        let(:account_id) { account.id }

        run_test!
      end

      response '200', 'holdings filtered by date range' do
        schema '$ref' => '#/components/schemas/HoldingCollection'

        let(:start_date) { (Date.current - 7.days).to_s }
        let(:end_date) { Date.current.to_s }

        run_test!
      end

      response '200', 'holdings filtered by security' do
        schema '$ref' => '#/components/schemas/HoldingCollection'

        let(:security_id) { security.id }

        run_test!
      end

      response '200', 'holdings paginated' do
        schema '$ref' => '#/components/schemas/HoldingCollection'

        let(:page) { 1 }
        let(:per_page) { 10 }

        run_test!
      end

      response '401', 'unauthorized' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { nil }

        run_test!
      end

      response '422', 'invalid date filter' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:start_date) { 'not-a-date' }

        run_test!
      end
    end
  end

  path '/api/v1/holdings/{id}' do
    parameter name: :id, in: :path, type: :string, required: true, description: 'Holding ID'

    get 'Retrieve holding' do
      tags 'Holdings'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      response '200', 'holding retrieved' do
        schema '$ref' => '#/components/schemas/Holding'

        let(:id) { holding.id }

        run_test!
      end

      response '401', 'unauthorized' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { holding.id }
        let(:'X-Api-Key') { nil }

        run_test!
      end

      response '404', 'holding not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { SecureRandom.uuid }

        run_test!
      end
    end
  end
end
