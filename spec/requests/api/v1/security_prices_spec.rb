# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'API V1 Security Prices', type: :request do
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
    # Persist an invalid key shape intentionally so rswag can document 403.
    ApiKey.new(
      user: user,
      name: 'No Read Docs Key',
      key: key,
      scopes: [],
      source: 'web'
    ).tap { |api_key| api_key.save!(validate: false) }
  end

  let(:'X-Api-Key') { api_key.plain_key }

  let(:account) do
    Account.create!(
      family: family,
      owner: user,
      name: 'Investment Account',
      balance: 50_000,
      currency: 'USD',
      accountable: Investment.create!
    )
  end

  let!(:security) do
    Security.create!(
      ticker: 'VTI',
      name: 'Vanguard Total Stock Market ETF',
      country_code: 'US',
      exchange_operating_mic: 'ARCX'
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

  let!(:security_price) do
    Security::Price.create!(
      security: security,
      date: Date.current,
      price: 250.1234,
      currency: 'USD'
    )
  end

  path '/api/v1/security_prices' do
    get 'List security price history referenced by family investment data' do
      tags 'Security Prices'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'
      parameter name: :page, in: :query, type: :integer, required: false,
                description: 'Page number (default: 1)'
      parameter name: :per_page, in: :query, type: :integer, required: false,
                description: 'Items per page (default: 25, max: 100)'
      parameter name: :security_id, in: :query, required: false,
                description: 'Filter by security ID',
                schema: { type: :string, format: :uuid }
      parameter name: :currency, in: :query, required: false,
                description: 'Filter by currency code',
                schema: { type: :string }
      parameter name: :start_date, in: :query, required: false,
                description: 'Filter prices from this date',
                schema: { type: :string, format: :date }
      parameter name: :end_date, in: :query, required: false,
                description: 'Filter prices until this date',
                schema: { type: :string, format: :date }
      parameter name: :provisional, in: :query, required: false,
                description: 'Filter by provisional price status. When supplied, must be true or false.',
                schema: { type: :boolean }

      response '200', 'security prices listed' do
        schema '$ref' => '#/components/schemas/SecurityPriceCollection'

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

        let(:security_id) { 'not-a-uuid' }

        run_test!
      end
    end

    post 'Import closing prices for a security no provider tracks' do
      description <<~DESC.squish
        Self-hosted instances only. Stores daily closes for an offline security no provider has
        ever matched (no offline_reason, no price_provider) that is traded in an account the caller can write to, or held in a linked one. All rows
        are validated first and stored together, or none are. A date already stored is replaced.
        Security prices are shared, so the closes also value any other family holding the same
        security. The caller's affected accounts are synced afterwards. Requires the read_write scope.
      DESC
      tags 'Security Prices'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json'
      produces 'application/json'
      parameter name: :body, in: :body, required: true, schema: { '$ref' => '#/components/schemas/SecurityPriceImportRequest' }

      let(:offline_security) do
        Security.create!(ticker: 'MYFUND', name: 'Private fund', offline: true).tap do |offline|
          account.entries.create!(
            date: Date.current, name: 'Buy', amount: 120, currency: 'USD',
            entryable: Trade.new(security: offline, qty: 10, price: 12, currency: 'USD')
          )
        end
      end
      let(:body) do
        { security_id: offline_security.id, prices: [ { date: Date.current.iso8601, price: '12.3400', currency: 'USD' } ] }
      end

      before do
        allow(Rails.application.config).to receive(:app_mode).and_return('self_hosted'.inquiry)
        allow_any_instance_of(ApplicationController).to receive(:redis_connected?).and_return(true)
      end

      response '200', 'closes imported' do
        schema '$ref' => '#/components/schemas/SecurityPriceImportResult'

        run_test!
      end

      response '403', 'insufficient scope, a guest, or a managed instance' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        before { allow(Rails.application.config).to receive(:app_mode).and_return('managed'.inquiry) }

        run_test!
      end

      response '404', 'security not found among the caller\'s writable accounts' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:body) { { security_id: SecureRandom.uuid, prices: [ { date: Date.current.iso8601, price: '12', currency: 'USD' } ] } }

        run_test!
      end

      response '422', 'online security or invalid rows; nothing was stored' do
        schema '$ref' => '#/components/schemas/SecurityPriceImportError'

        let(:body) { { security_id: offline_security.id, prices: [ { date: Date.current.iso8601, price: '-1', currency: 'USD' } ] } }

        run_test!
      end
    end
  end

  path '/api/v1/security_prices/{id}' do
    parameter name: :id, in: :path, required: true, description: 'Security price ID',
              schema: { type: :string, format: :uuid }

    get 'Retrieve a security price referenced by family investment data' do
      tags 'Security Prices'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      let(:id) { security_price.id }

      response '200', 'security price retrieved' do
        schema '$ref' => '#/components/schemas/SecurityPrice'

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

      response '404', 'security price not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { SecureRandom.uuid }

        run_test!
      end
    end
  end
end
