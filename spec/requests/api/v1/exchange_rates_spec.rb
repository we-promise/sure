# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'API V1 Exchange Rates', type: :request do
  before do
    allow(Rails.configuration).to receive(:app_mode).and_return('self_hosted'.inquiry)
  end

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
      display_key: key,
      scopes: %w[read_write],
      source: 'web'
    )
  end

  let(:read_only_api_key) do
    key = ApiKey.generate_secure_key
    ApiKey.create!(
      user: user,
      name: 'Read Only Docs Key',
      key: key,
      display_key: key,
      scopes: %w[read],
      source: 'mobile'
    )
  end

  let(:'X-Api-Key') { api_key.plain_key }

  let!(:exchange_rate) do
    ExchangeRate.create!(
      from_currency: 'EUR',
      to_currency: 'USD',
      date: Date.new(2026, 6, 1),
      rate: 1.08
    )
  end

  path '/api/v1/exchange_rates' do
    get 'List exchange rates' do
      tags 'Exchange Rates'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'
      parameter name: :page, in: :query, type: :integer, required: false,
                description: 'Page number (default: 1)'
      parameter name: :per_page, in: :query, type: :integer, required: false,
                description: 'Items per page (default: 25, max: 100)'
      parameter name: :from, in: :query, required: false,
                description: 'Filter by source currency (ISO 4217)',
                schema: { type: :string }
      parameter name: :to, in: :query, required: false,
                description: 'Filter by target currency (ISO 4217)',
                schema: { type: :string }
      parameter name: :start_date, in: :query, required: false,
                description: 'Filter rates from this date',
                schema: { type: :string, format: :date }
      parameter name: :end_date, in: :query, required: false,
                description: 'Filter rates until this date',
                schema: { type: :string, format: :date }

      response '200', 'exchange rates listed' do
        schema '$ref' => '#/components/schemas/ExchangeRateCollection'

        run_test!
      end

      response '401', 'unauthorized' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { nil }

        run_test!
      end

      response '422', 'invalid filter' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:from) { 'NOPE' }

        run_test!
      end
    end

    post 'Create or update an exchange rate' do
      tags 'Exchange Rates'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json'
      produces 'application/json'
      description 'Idempotent upsert keyed on (from, to, date): posting an existing pair and date updates the stored rate and returns 200 instead of 201. Only available on self-hosted instances (exchange rates are global) and requires the read_write scope.'
      parameter name: :body, in: :body, schema: {
        type: :object,
        required: %w[from to date rate],
        properties: {
          from: { type: :string, description: 'ISO 4217 source currency code' },
          to: { type: :string, description: 'ISO 4217 target currency code' },
          date: { type: :string, format: :date },
          rate: { type: :string, description: 'Positive decimal exchange rate' }
        }
      }

      response '201', 'exchange rate created' do
        schema '$ref' => '#/components/schemas/ExchangeRate'

        let(:body) { { from: 'GBP', to: 'USD', date: '2026-06-01', rate: '1.27' } }

        run_test!
      end

      response '200', 'exchange rate updated (idempotent upsert)' do
        schema '$ref' => '#/components/schemas/ExchangeRate'

        let(:body) { { from: 'EUR', to: 'USD', date: '2026-06-01', rate: '1.10' } }

        run_test!
      end

      response '403', 'read-only key cannot write' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { read_only_api_key.plain_key }
        let(:body) { { from: 'GBP', to: 'USD', date: '2026-06-01', rate: '1.27' } }

        run_test!
      end

      response '422', 'validation error' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:body) { { from: 'GBP', to: 'USD', date: '2026-06-01', rate: '-1' } }

        run_test!
      end
    end
  end

  path '/api/v1/exchange_rates/{id}' do
    parameter name: :id, in: :path, description: 'Exchange rate ID', required: true,
              schema: { type: :string, format: :uuid }

    get 'Show exchange rate' do
      tags 'Exchange Rates'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      response '200', 'exchange rate found' do
        schema '$ref' => '#/components/schemas/ExchangeRate'

        let(:id) { exchange_rate.id }

        run_test!
      end

      response '404', 'exchange rate not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { SecureRandom.uuid }

        run_test!
      end

      response '401', 'unauthorized' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { exchange_rate.id }
        let(:'X-Api-Key') { nil }

        run_test!
      end
    end
  end
end
