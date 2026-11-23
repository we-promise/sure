# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'API V1 Trades', type: :request do
  # POST /api/v1/trades answers 201 with one of three shapes. rswag keeps a
  # single 201 entry per operation (the last example's schema, deep-merged), so
  # every 201 example declares the same documented oneOf and then checks its own
  # response against the one schema it should match.
  created_response_schema = {
    oneOf: [
      { '$ref' => '#/components/schemas/Trade' },
      { '$ref' => '#/components/schemas/Transaction' },
      { '$ref' => '#/components/schemas/TransferDecision' }
    ]
  }

  def expect_created_shape(response, schema_name)
    metadata = RSpec.current_example.metadata.deep_dup
    metadata[:response][:schema] = { '$ref' => "#/components/schemas/#{schema_name}" }
    Rswag::Specs::ResponseValidator.new.validate!(metadata, response)
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
      scopes: %w[read_write],
      source: 'web'
    )
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

  let(:security) do
    Security.create!(
      ticker: 'VTI',
      name: 'Vanguard Total Stock Market ETF',
      country_code: 'US'
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

  let(:read_only_trade) do
    owner = family.users.create!(
      email: 'api-owner@example.com',
      password: 'password123',
      password_confirmation: 'password123'
    )
    shared_account = Account.create!(
      family: family,
      owner: owner,
      name: 'Shared Brokerage',
      balance: 50_000,
      currency: 'USD',
      accountable: Investment.create!
    )
    shared_account.account_shares.create!(user: user, permission: 'read_only', include_in_finances: true)
    shared_account.entries.create!(
      name: 'Buy shared shares',
      date: Date.current,
      amount: 1_000,
      currency: 'USD',
      entryable: Trade.new(security: security, qty: 10, price: 100, currency: 'USD', investment_activity_label: 'Buy')
    ).entryable
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
              qty: { type: :number, description: 'Quantity (required for buy/sell/sweep_in/sweep_out/reinvestment)' },
              price: { type: :number, description: 'Price (required for buy/sell/sweep_in/sweep_out/reinvestment)' },
              amount: {
                type: :number,
                description: 'Amount (required for dividend, deposit, withdrawal, interest, fee)'
              },
              fee: {
                type: :number,
                minimum: 0,
                description: 'Optional fee (buy/sell/sweep_in/sweep_out/reinvestment)'
              },
              type: {
                type: :string,
                enum: %w[buy sell sweep_in sweep_out dividend reinvestment interest fee deposit withdrawal],
                description: 'Trade type (required)'
              },
              security_id: { type: :string, format: :uuid, description: 'Security ID (one of security_id, ticker, manual_ticker required)' },
              ticker: { type: :string, description: 'Ticker symbol' },
              manual_ticker: { type: :string, description: 'Manual ticker for offline securities' },
              currency: { type: :string, description: 'Currency (defaults to account currency)' },
              investment_activity_label: { type: :string, description: 'Activity label (e.g. Buy, Sell)' },
              transfer_account_id: { type: :string, format: :uuid, description: 'Destination/source account ID for linked transfers. Must be an account the user can write to; otherwise the request returns 404.' }
            },
            required: %w[account_id date type]
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
        schema created_response_schema

        run_test! do |response|
          expect_created_shape(response, 'Trade')
        end
      end

      response '403', 'forbidden - api key missing read_write scope' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:read_only_api_key) do
          key = ApiKey.generate_secure_key
          ApiKey.create!(
            user: user,
            name: 'API Docs Read Key',
            key: key,
            scopes: %w[read],
            source: 'mobile'
          )
        end
        let(:'X-Api-Key') { read_only_api_key.plain_key }

        run_test!
      end

      response '401', 'unauthorized - missing api key' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { nil }

        run_test!
      end

      response '422', 'invalid date format' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:body) do
          {
            trade: {
              account_id: account.id,
              date: 'invalid-date',
              qty: 10,
              price: 50,
              type: 'buy',
              security_id: security.id
            }
          }
        end

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

      response '201', 'dividend created with security' do
        schema created_response_schema

        let(:body) do
          {
            trade: {
              account_id: account.id,
              date: Date.current.to_s,
              type: 'dividend',
              amount: 25.50,
              currency: 'USD',
              ticker: 'AAPL'
            }
          }
        end

        run_test! do |response|
          expect_created_shape(response, 'Trade')
        end
      end

      response '422', 'dividend without security returns error' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:body) do
          {
            trade: {
              account_id: account.id,
              date: Date.current.to_s,
              type: 'dividend',
              amount: 25.50
            }
          }
        end

        run_test!
      end

      response '422', 'dividend without amount returns error' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:body) do
          {
            trade: {
              account_id: account.id,
              date: Date.current.to_s,
              type: 'dividend',
              ticker: 'AAPL'
            }
          }
        end

        run_test!
      end

      response '422', 'invalid type returns error' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:body) do
          {
            trade: {
              account_id: account.id,
              date: Date.current.to_s,
              type: 'invalid'
            }
          }
        end

        run_test!
      end

      response '201', 'deposit created' do
        schema created_response_schema

        let(:body) do
          {
            trade: {
              account_id: account.id,
              date: Date.current.to_s,
              type: 'deposit',
              amount: 175.25,
              currency: 'USD'
            }
          }
        end

        run_test! do |response|
          expect_created_shape(response, 'Transaction')
        end
      end

      response '201', 'withdrawal created' do
        schema created_response_schema

        let(:body) do
          {
            trade: {
              account_id: account.id,
              date: Date.current.to_s,
              type: 'withdrawal',
              amount: 100.00,
              currency: 'USD'
            }
          }
        end

        run_test! do |response|
          expect_created_shape(response, 'Transaction')
        end
      end

      response '201', 'linked transfer created (deposit or withdrawal with transfer_account_id)' do
        schema created_response_schema

        let(:transfer_account) do
          Account.create!(
            family: family,
            name: 'Checking Account',
            balance: 10_000,
            currency: 'USD',
            accountable: Depository.create!
          )
        end

        let(:body) do
          {
            trade: {
              account_id: account.id,
              date: Date.current.to_s,
              type: 'withdrawal',
              amount: 100.00,
              currency: 'USD',
              transfer_account_id: transfer_account.id
            }
          }
        end

        run_test! do |response|
          expect_created_shape(response, 'TransferDecision')
        end
      end

      response '201', 'created: a Trade for trade types, a Transaction for a deposit or withdrawal without transfer_account_id, or a TransferDecision for a deposit or withdrawal with transfer_account_id' do
        schema created_response_schema

        let(:body) do
          {
            trade: {
              account_id: account.id,
              date: Date.current.to_s,
              type: 'interest',
              amount: 25.00,
              currency: 'USD'
            }
          }
        end

        run_test! do |response|
          expect_created_shape(response, 'Trade')
        end
      end

      response '422', 'invalid trade request' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:body) do
          {
            trade: {
              account_id: account.id,
              date: Date.current.to_s,
              type: 'deposit'
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
              qty: { type: :number, description: 'Positive quantity. Sending qty, price, type or nature recomputes the entry amount as signed qty * price + fee, where qty is negative on a sell; what the request leaves out is taken from the trade.' },
              price: { type: :number, description: 'Positive price per unit' },
              type: { type: :string, enum: %w[buy sell sweep_in sweep_out reinvestment], description: 'Side of the trade; takes precedence over nature' },
              nature: { type: :string, enum: %w[inflow outflow], description: 'inflow is a sell, outflow a buy' },
              name: { type: :string },
              notes: { type: :string },
              currency: { type: :string },
              investment_activity_label: { type: :string }
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

      response '401', 'unauthorized' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { trade.id }
        let(:'X-Api-Key') { nil }

        run_test!
      end

      response '403', 'forbidden - api key missing read_write scope, or the account is shared with you without write access' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { trade.id }
        let(:read_only_api_key) do
          key = ApiKey.generate_secure_key
          ApiKey.create!(
            user: user,
            name: 'API Docs Read Key',
            key: key,
            scopes: %w[read],
            source: 'mobile'
          )
        end
        let(:'X-Api-Key') { read_only_api_key.plain_key }

        run_test!
      end

      response '403', 'forbidden - api key missing read_write scope, or the account is shared with you without write access' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { read_only_trade.id }

        run_test!
      end

      response '404', 'trade not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { SecureRandom.uuid }

        run_test!
      end

      response '422', 'qty or price is not a positive number, or nature is not inflow or outflow' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { trade.id }
        let(:body) { { trade: { price: 'abc' } } }

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

      response '401', 'unauthorized' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { trade.id }
        let(:'X-Api-Key') { nil }

        run_test!
      end

      response '403', 'forbidden - api key missing read_write scope, or the account is shared with you without write access' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { trade.id }
        let(:read_only_api_key) do
          key = ApiKey.generate_secure_key
          ApiKey.create!(
            user: user,
            name: 'API Docs Read Key',
            key: key,
            scopes: %w[read],
            source: 'mobile'
          )
        end
        let(:'X-Api-Key') { read_only_api_key.plain_key }

        run_test!
      end

      response '403', 'forbidden - api key missing read_write scope, or the account is shared with you without write access' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { read_only_trade.id }

        run_test!
      end

      response '422', 'trade belongs to a managed Bitcoin position' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) do
          crypto_account = Account.create!(family: family, owner: user, name: 'Bitcoin', balance: 0, currency: 'USD', accountable: Crypto.create!)
          bitcoin = Security.create!(ticker: 'CRYPTO:BTC', name: 'Bitcoin', country_code: 'US')
          record = Account::ProviderImportAdapter.new(crypto_account).import_trade(
            security: bitcoin, quantity: 1, price: 20, amount: 20, currency: 'USD',
            date: Date.current, source: 'demo')
          item = family.onchain_wallet_items.create!(name: 'Wallets')
          wallet = BitcoinWalletAccount.create!(account: crypto_account, security: bitcoin, onchain_wallet_item: item,
            baseline_at: Time.current, status: :active)
          wallet.create_account_provider!(account: crypto_account)
          record.trade.id
        end

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
