# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'API V1 Trades', type: :request do
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

  let(:category) do
    family.categories.create!(
      name: 'Investments',
      classification: 'expense',
      color: '#2196F3',
      lucide_icon: 'trending-up'
    )
  end

  let!(:trade) do
    trade_record = Trade.new(
      security: security,
      qty: 100,
      price: 250.50,
      currency: 'USD',
      investment_activity_label: 'Buy'
    )
    entry = account.entries.create!(
      name: 'Buy 100 shares of VTI',
      date: Date.current,
      amount: 25_050,
      currency: 'USD',
      entryable: trade_record
    )
    entry.entryable
  end

  path '/api/v1/trades' do
    get 'List trades' do
      tags 'Trades'
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
      parameter name: :start_date, in: :query, required: false,
                description: 'Filter trades from this date (inclusive)',
                schema: { type: :string, format: :date }
      parameter name: :end_date, in: :query, required: false,
                description: 'Filter trades until this date (inclusive)',
                schema: { type: :string, format: :date }

      response '200', 'trades listed' do
        schema '$ref' => '#/components/schemas/TradeCollection'

        run_test!
      end

      response '200', 'trades filtered by account' do
        schema '$ref' => '#/components/schemas/TradeCollection'

        let(:account_id) { account.id }

        run_test!
      end

      response '200', 'trades filtered by date range' do
        schema '$ref' => '#/components/schemas/TradeCollection'

        let(:start_date) { (Date.current - 7.days).to_s }
        let(:end_date) { Date.current.to_s }

        run_test!
      end

      response '200', 'trades paginated' do
        schema '$ref' => '#/components/schemas/TradeCollection'

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

    post 'Create trade' do
      tags 'Trades'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json'
      produces 'application/json'
      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        properties: {
          trade: {
            type: :object,
            properties: {
              account_id: { type: :string, format: :uuid, description: 'Account ID (required)' },
              date: { type: :string, format: :date, description: 'Trade date (required)' },
              qty: { type: :number, description: 'Quantity (required)' },
              price: { type: :number, description: 'Price (required)' },
              type: { type: :string, enum: %w[buy sell], description: 'Trade type (required)' },
              security_id: { type: :string, format: :uuid, description: 'Security ID (one of security_id, ticker, manual_ticker required)' },
              ticker: { type: :string, description: 'Ticker symbol' },
              manual_ticker: { type: :string, description: 'Manual ticker for offline securities' },
              currency: { type: :string, description: 'Currency (defaults to account currency)' },
              investment_activity_label: { type: :string, description: 'Activity label (e.g. Buy, Sell)' },
              category_id: { type: :string, format: :uuid, description: 'Category ID' }
            },
            required: %w[account_id date qty price type]
          }
        },
        required: %w[trade]
      }

      let(:body) do
        {
          trade: {
            account_id: account.id,
            date: Date.current.to_s,
            qty: 50,
            price: 100.00,
            type: 'buy',
            security_id: security.id
          }
        }
      end

      response '201', 'trade created' do
        schema '$ref' => '#/components/schemas/Trade'

        run_test!
      end

      response '422', 'account does not support trades' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:checking_account) do
          Account.create!(
            family: family,
            name: 'Checking',
            balance: 1000,
            currency: 'USD',
            accountable: Depository.create!
          )
        end
        let(:body) do
          {
            trade: {
              account_id: checking_account.id,
              date: Date.current.to_s,
              qty: 10,
              price: 50,
              type: 'buy',
              security_id: security.id
            }
          }
        end

        run_test!
      end

      response '404', 'account not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:body) do
          {
            trade: {
              account_id: SecureRandom.uuid,
              date: Date.current.to_s,
              qty: 10,
              price: 50,
              type: 'buy',
              security_id: security.id
            }
          }
        end

        run_test!
      end

      response '422', 'validation error - missing type' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:body) do
          {
            trade: {
              account_id: account.id,
              date: Date.current.to_s,
              qty: 10,
              price: 50,
              security_id: security.id
            }
          }
        end

        run_test!
      end

      response '422', 'validation error - missing security identifier' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:body) do
          {
            trade: {
              account_id: account.id,
              date: Date.current.to_s,
              qty: 10,
              price: 50,
              type: 'buy'
            }
          }
        end

        run_test!
      end
    end
  end

  path '/api/v1/trades/{id}' do
    parameter name: :id, in: :path, type: :string, required: true, description: 'Trade ID'

    get 'Retrieve trade' do
      tags 'Trades'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      response '200', 'trade retrieved' do
        schema '$ref' => '#/components/schemas/Trade'

        let(:id) { trade.id }

        run_test!
      end

      response '401', 'unauthorized' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { trade.id }
        let(:'X-Api-Key') { nil }

        run_test!
      end

      response '404', 'trade not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { SecureRandom.uuid }

        run_test!
      end
    end

    patch 'Update trade' do
      tags 'Trades'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json'
      produces 'application/json'

      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        properties: {
          trade: {
            type: :object,
            properties: {
              date: { type: :string, format: :date },
              qty: { type: :number },
              price: { type: :number },
              type: { type: :string, enum: %w[buy sell] },
              nature: { type: :string, enum: %w[inflow outflow] },
              name: { type: :string },
              notes: { type: :string },
              currency: { type: :string },
              investment_activity_label: { type: :string },
              category_id: { type: :string, format: :uuid }
            }
          }
        }
      }

      let(:body) do
        {
          trade: {
            qty: 75,
            price: 255.00,
            type: 'buy'
          }
        }
      end

      response '200', 'trade updated' do
        schema '$ref' => '#/components/schemas/Trade'

        let(:id) { trade.id }

        run_test!
      end

      response '404', 'trade not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { SecureRandom.uuid }

        run_test!
      end
    end

    delete 'Delete trade' do
      tags 'Trades'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      response '200', 'trade deleted' do
        schema '$ref' => '#/components/schemas/DeleteResponse'

        let(:id) { trade.id }

        run_test!
      end

      response '404', 'trade not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { SecureRandom.uuid }

        run_test!
      end
    end
  end
end
