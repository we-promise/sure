# frozen_string_literal: true

require 'swagger_helper'

# Docs-only rswag spec (no behavioral assertions) — see
# .cursor/rules/api-endpoint-consistency.mdc. Behavior is covered by
# test/controllers/api/v1/splits_controller_test.rb.
RSpec.describe 'API V1 Transaction Splits', type: :request do
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

  let(:read_only_api_key) do
    key = ApiKey.generate_secure_key
    ApiKey.create!(
      user: user,
      name: 'API Docs Read-Only Key',
      key: key,
      scopes: %w[read],
      source: 'mobile'
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
      color: '#4CAF50',
      lucide_icon: 'shopping-cart'
    )
  end

  let!(:splittable_transaction) do
    entry = account.entries.create!(
      name: 'Grocery shopping',
      date: Date.current,
      amount: 75.50,
      currency: 'USD',
      entryable: Transaction.new
    )
    entry.transaction
  end

  let!(:split_transaction) do
    entry = account.entries.create!(
      name: 'Warehouse run',
      date: Date.current,
      amount: 100.00,
      currency: 'USD',
      entryable: Transaction.new
    )
    entry.split!([
      { name: 'Groceries', amount: 60.00, category_id: category.id },
      { name: 'Household', amount: 40.00 }
    ])
    entry.transaction
  end

  path '/api/v1/transactions/{transaction_id}/split' do
    parameter name: :transaction_id, in: :path, type: :string, description: 'Transaction ID'

    post 'Split a transaction' do
      tags 'Transaction Splits'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json'
      produces 'application/json'
      description 'Splits a transaction into child transactions. Amounts are signed to match the parent transaction and must sum to the parent amount.'

      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        properties: {
          split: {
            type: :object,
            properties: {
              splits: {
                type: :array,
                items: {
                  type: :object,
                  properties: {
                    name: { type: :string },
                    amount: { type: :number, description: 'Signed to match the parent transaction' },
                    category_id: { type: :string, format: :uuid },
                    excluded: { type: :boolean }
                  },
                  required: %w[amount]
                }
              }
            },
            required: %w[splits]
          }
        },
        required: %w[split]
      }

      let(:transaction_id) { splittable_transaction.id }
      let(:body) do
        {
          split: {
            splits: [
              { name: 'Groceries', amount: 50.50, category_id: category.id },
              { name: 'Household', amount: 25.00 }
            ]
          }
        }
      end

      response '201', 'transaction split' do
        schema '$ref' => '#/components/schemas/Transaction'
        run_test!
      end

      response '422', 'validation error - invalid splits (sum mismatch, empty list, or missing amount)' do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        let(:body) do
          { split: { splits: [ { name: 'Partial', amount: 10.00 } ] } }
        end
        run_test!
      end

      response '404', 'transaction not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        let(:transaction_id) { SecureRandom.uuid }
        run_test!
      end

      response '401', 'missing or invalid API key' do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        let(:'X-Api-Key') { '' }
        run_test!
      end

      response '403', 'read-only key cannot write' do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        let(:'X-Api-Key') { read_only_api_key.plain_key }
        run_test!
      end
    end

    patch 'Replace splits on a transaction' do
      tags 'Transaction Splits'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json'
      produces 'application/json'
      description 'Replaces the existing splits on a split parent. Accepts the parent or any child transaction id.'

      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        properties: {
          split: {
            type: :object,
            properties: {
              splits: {
                type: :array,
                items: {
                  type: :object,
                  properties: {
                    name: { type: :string },
                    amount: { type: :number },
                    category_id: { type: :string, format: :uuid },
                    excluded: { type: :boolean }
                  },
                  required: %w[amount]
                }
              }
            },
            required: %w[splits]
          }
        },
        required: %w[split]
      }

      let(:transaction_id) { split_transaction.id }
      let(:body) do
        {
          split: {
            splits: [
              { name: 'Dining', amount: 80.00, category_id: category.id },
              { name: 'Tip', amount: 20.00 }
            ]
          }
        }
      end

      response '200', 'splits replaced' do
        schema '$ref' => '#/components/schemas/Transaction'
        run_test!
      end

      response '422', 'validation error - invalid splits (sum mismatch, empty list, or missing amount)' do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        let(:body) do
          { split: { splits: [ { name: 'Partial', amount: 10.00 } ] } }
        end
        run_test!
      end

      response '401', 'missing or invalid API key' do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        let(:'X-Api-Key') { '' }
        run_test!
      end

      response '403', 'read-only key cannot write' do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        let(:'X-Api-Key') { read_only_api_key.plain_key }
        run_test!
      end

      response '404', 'transaction not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        let(:transaction_id) { SecureRandom.uuid }
        run_test!
      end
    end

    delete 'Remove splits from a transaction' do
      tags 'Transaction Splits'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'
      description 'Removes all split children and restores the parent transaction.'

      let(:transaction_id) { split_transaction.id }

      response '200', 'splits removed' do
        schema '$ref' => '#/components/schemas/Transaction'
        run_test!
      end

      response '401', 'missing or invalid API key' do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        let(:'X-Api-Key') { '' }
        run_test!
      end

      response '403', 'read-only key cannot write' do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        let(:'X-Api-Key') { read_only_api_key.plain_key }
        run_test!
      end

      response '404', 'transaction not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        let(:transaction_id) { SecureRandom.uuid }
        run_test!
      end
    end
  end
end
