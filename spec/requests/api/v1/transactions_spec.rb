# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'API V1 Transactions', type: :request do
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
      name: 'Checking Account',
      balance: 1000,
      currency: 'USD',
      accountable: Depository.create!
    )
  end

  let(:category) do
    family.categories.create!(
      name: 'Groceries',
      classification: 'expense',
      color: '#4CAF50',
      lucide_icon: 'shopping-cart'
    )
  end

  let(:merchant) do
    family.merchants.create!(name: 'Whole Foods')
  end

  let(:tag) do
    family.tags.create!(name: 'Essential', color: '#2196F3')
  end

  let!(:transaction) do
    entry = account.entries.create!(
      name: 'Grocery shopping',
      date: Date.current,
      amount: 75.50,
      currency: 'USD',
      entryable: Transaction.new(
        category: category,
        merchant: merchant
      )
    )
    entry.transaction.tags << tag
    entry.transaction
  end

  let!(:another_transaction) do
    entry = account.entries.create!(
      name: 'Coffee',
      date: Date.current - 1.day,
      amount: 5.00,
      currency: 'USD',
      entryable: Transaction.new
    )
    entry.transaction
  end

  path '/api/v1/transactions' do
    get 'List transactions' do
      tags 'Transactions'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'
      parameter name: :page, in: :query, type: :integer, required: false,
                description: 'Page number (default: 1)'
      parameter name: :per_page, in: :query, type: :integer, required: false,
                description: 'Items per page (default: 25, max: 100)'
      parameter name: :account_id, in: :query, type: :string, required: false,
                description: 'Filter by account ID'
      parameter name: :category_id, in: :query, type: :string, required: false,
                description: 'Filter by category ID'
      parameter name: :merchant_id, in: :query, type: :string, required: false,
                description: 'Filter by merchant ID'
      parameter name: :start_date, in: :query, required: false,
                description: 'Filter transactions from this date',
                schema: { type: :string, format: :date }
      parameter name: :end_date, in: :query, required: false,
                description: 'Filter transactions until this date',
                schema: { type: :string, format: :date }
      parameter name: :min_amount, in: :query, type: :number, required: false,
                description: 'Filter by minimum amount'
      parameter name: :max_amount, in: :query, type: :number, required: false,
                description: 'Filter by maximum amount'
      parameter name: :type, in: :query, required: false,
                description: 'Filter by transaction type',
                schema: { type: :string, enum: %w[income expense] }
      parameter name: :search, in: :query, type: :string, required: false,
                description: 'Search by name, notes, or merchant name'
      parameter name: :account_ids, in: :query, required: false,
                description: 'Filter by multiple account IDs',
                schema: { type: :array, items: { type: :string } }
      parameter name: :category_ids, in: :query, required: false,
                description: 'Filter by multiple category IDs',
                schema: { type: :array, items: { type: :string } }
      parameter name: :merchant_ids, in: :query, required: false,
                description: 'Filter by multiple merchant IDs',
                schema: { type: :array, items: { type: :string } }
      parameter name: :tag_ids, in: :query, required: false,
                description: 'Filter by tag IDs',
                schema: { type: :array, items: { type: :string } }

      response '200', 'transactions listed' do
        schema '$ref' => '#/components/schemas/TransactionCollection'

        run_test!
      end

      response '200', 'transactions filtered by account' do
        schema '$ref' => '#/components/schemas/TransactionCollection'

        let(:account_id) { account.id }

        run_test!
      end

      response '200', 'transactions filtered by date range' do
        schema '$ref' => '#/components/schemas/TransactionCollection'

        let(:start_date) { (Date.current - 7.days).to_s }
        let(:end_date) { Date.current.to_s }

        run_test!
      end
    end

    post 'Create transaction' do
      tags 'Transactions'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json'
      produces 'application/json'
      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        properties: {
          transaction: {
            type: :object,
            properties: {
              account_id: { type: :string, format: :uuid, description: 'Account ID (required)' },
              date: { type: :string, format: :date, description: 'Transaction date' },
              amount: { type: :number, description: 'Transaction amount' },
              name: { type: :string, description: 'Transaction name/description' },
              description: { type: :string, description: 'Alternative to name field' },
              notes: { type: :string, description: 'Additional notes' },
              currency: { type: :string, description: 'Currency code (defaults to family currency)' },
              category_id: { type: :string, format: :uuid, description: 'Category ID' },
              merchant_id: { type: :string, format: :uuid, description: 'Merchant ID' },
              nature: { type: :string, enum: %w[income expense inflow outflow], description: 'Transaction nature (determines sign)' },
              tag_ids: { type: :array, items: { type: :string, format: :uuid }, description: 'Array of tag IDs' }
            },
            required: %w[account_id date amount name]
          }
        },
        required: %w[transaction]
      }

      let(:body) do
        {
          transaction: {
            account_id: account.id,
            date: Date.current.to_s,
            amount: 50.00,
            name: 'Test purchase',
            nature: 'expense',
            category_id: category.id,
            merchant_id: merchant.id
          }
        }
      end

      response '201', 'transaction created' do
        schema '$ref' => '#/components/schemas/Transaction'

        run_test!
      end

      response '422', 'validation error - missing account_id' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:body) do
          {
            transaction: {
              date: Date.current.to_s,
              amount: 50.00,
              name: 'Test purchase'
            }
          }
        end

        run_test!
      end

      response '422', 'validation error - missing required fields' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:body) do
          {
            transaction: {
              account_id: account.id
            }
          }
        end

        run_test!
      end
    end
  end

  path '/api/v1/transactions/{id}' do
    parameter name: :id, in: :path, type: :string, required: true, description: 'Transaction ID'

    get 'Retrieve a transaction' do
      tags 'Transactions'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      let(:id) { transaction.id }

      response '200', 'transaction retrieved' do
        schema '$ref' => '#/components/schemas/Transaction'

        run_test!
      end

      response '404', 'transaction not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { SecureRandom.uuid }

        run_test!
      end
    end

    patch 'Update a transaction' do
      tags 'Transactions'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json'
      produces 'application/json'

      let(:id) { transaction.id }

      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        properties: {
          transaction: {
            type: :object,
            properties: {
              date: { type: :string, format: :date },
              amount: { type: :number },
              name: { type: :string },
              description: { type: :string, description: 'Alternative to name field' },
              notes: { type: :string },
              currency: { type: :string, description: 'Currency code' },
              category_id: { type: :string, format: :uuid },
              merchant_id: { type: :string, format: :uuid },
              nature: { type: :string, enum: %w[income expense inflow outflow] },
              tag_ids: {
                type: :array,
                items: { type: :string, format: :uuid },
                description: 'Array of tag IDs to assign. Omit to preserve existing tags; use [] to clear all tags.'
              }
            }
          }
        }
      }

      let(:body) do
        {
          transaction: {
            name: 'Updated grocery shopping',
            notes: 'Weekly groceries'
          }
        }
      end

      response '200', 'transaction updated' do
        schema '$ref' => '#/components/schemas/Transaction'

        run_test!
      end

      response '404', 'transaction not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { SecureRandom.uuid }

        run_test!
      end
    end

    delete 'Delete a transaction' do
      tags 'Transactions'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      let(:id) { another_transaction.id }

      response '200', 'transaction deleted' do
        schema '$ref' => '#/components/schemas/DeleteResponse'

        run_test!
      end

      response '404', 'transaction not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { SecureRandom.uuid }

        run_test!
      end
    end
  end
end
