# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'API V1 Recurring Transactions', type: :request do
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
      name: 'Read Only Docs Key',
      key: key,
      scopes: %w[read],
      source: 'mobile'
    )
  end

  let(:'X-Api-Key') { api_key.plain_key }

  let(:account) do
    Account.create!(
      family: family,
      owner: user,
      name: 'Checking Account',
      balance: 1000,
      currency: 'USD',
      accountable: Depository.create!
    )
  end

  let(:merchant) { family.merchants.create!(name: 'Streaming Service') }

  let!(:recurring_transaction) do
    family.recurring_transactions.create!(
      account: account,
      merchant: merchant,
      amount: 19.99,
      currency: 'USD',
      expected_day_of_month: 15,
      last_occurrence_date: Date.new(2026, 4, 15),
      next_expected_date: Date.new(2026, 5, 15),
      status: 'active',
      occurrence_count: 3,
      manual: true
    )
  end

  path '/api/v1/recurring_transactions' do
    get 'List recurring transactions' do
      tags 'Recurring Transactions'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'
      parameter name: :page, in: :query, type: :integer, required: false,
                description: 'Page number (default: 1)'
      parameter name: :per_page, in: :query, type: :integer, required: false,
                description: 'Items per page (default: 25, max: 100)'
      parameter name: :status, in: :query, required: false,
                description: 'Filter by recurring status',
                schema: { type: :string, enum: %w[active inactive] }
      parameter name: :account_id, in: :query, required: false, description: 'Filter by account ID',
                schema: { type: :string, format: :uuid }

      response '200', 'recurring transactions listed' do
        schema '$ref' => '#/components/schemas/RecurringTransactionCollection'

        run_test!
      end

      response '401', 'unauthorized' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { nil }

        run_test!
      end

      response '422', 'validation error - malformed account filter' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:account_id) { 'not-a-uuid' }

        run_test!
      end
    end

    post 'Create recurring transaction' do
      tags 'Recurring Transactions'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json'
      produces 'application/json'
      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        properties: {
          recurring_transaction: {
            type: :object,
            properties: {
              account_id: { type: :string, format: :uuid, nullable: true },
              merchant_id: { type: :string, format: :uuid, nullable: true },
              name: { type: :string, nullable: true },
              amount: { type: :number },
              currency: { type: :string },
              expected_day_of_month: { type: :integer, minimum: 1, maximum: 31 },
              last_occurrence_date: { type: :string, format: :date },
              next_expected_date: { type: :string, format: :date },
              status: { type: :string, enum: %w[active inactive] },
              occurrence_count: { type: :integer, minimum: 0 },
              manual: { type: :boolean },
              expected_amount_min: { type: :number, nullable: true },
              expected_amount_max: { type: :number, nullable: true },
              expected_amount_avg: { type: :number, nullable: true }
            },
            required: %w[amount currency expected_day_of_month last_occurrence_date next_expected_date],
            anyOf: [
              { required: %w[name] },
              { required: %w[merchant_id] }
            ]
          }
        },
        required: %w[recurring_transaction]
      }

      let(:body) do
        {
          recurring_transaction: {
            account_id: account.id,
            name: 'Gym Membership',
            amount: 49.99,
            currency: 'USD',
            expected_day_of_month: 1,
            last_occurrence_date: '2026-04-01',
            next_expected_date: '2026-05-01'
          }
        }
      end

      response '201', 'recurring transaction created' do
        schema '$ref' => '#/components/schemas/RecurringTransaction'

        run_test!
      end

      response '401', 'unauthorized' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { nil }

        run_test!
      end

      response '403', 'forbidden - requires read_write scope' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { read_only_api_key.plain_key }

        run_test!
      end

      response '404', 'account not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:body) do
          {
            recurring_transaction: {
              account_id: SecureRandom.uuid,
              name: 'Gym Membership',
              amount: 49.99,
              currency: 'USD',
              expected_day_of_month: 1,
              last_occurrence_date: '2026-04-01',
              next_expected_date: '2026-05-01'
            }
          }
        end

        run_test!
      end

      response '422', 'validation error - missing merchant or name' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:body) do
          {
            recurring_transaction: {
              account_id: account.id,
              amount: 49.99,
              currency: 'USD',
              expected_day_of_month: 1,
              last_occurrence_date: '2026-04-01',
              next_expected_date: '2026-05-01'
            }
          }
        end

        run_test!
      end

      response '422', 'validation error - nil status' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:body) do
          {
            recurring_transaction: {
              account_id: account.id,
              name: 'Gym Membership',
              amount: 49.99,
              currency: 'USD',
              expected_day_of_month: 1,
              last_occurrence_date: '2026-04-01',
              next_expected_date: '2026-05-01',
              status: nil
            }
          }
        end

        run_test!
      end

      response '422', 'validation error - negative occurrence count' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:body) do
          {
            recurring_transaction: {
              account_id: account.id,
              name: 'Gym Membership',
              amount: 49.99,
              currency: 'USD',
              expected_day_of_month: 1,
              last_occurrence_date: '2026-04-01',
              next_expected_date: '2026-05-01',
              occurrence_count: -1
            }
          }
        end

        run_test!
      end
    end
  end

  path '/api/v1/recurring_transactions/{id}' do
    parameter name: :id, in: :path, type: :string, required: true, description: 'Recurring transaction ID'

    get 'Retrieve recurring transaction' do
      tags 'Recurring Transactions'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      let(:id) { recurring_transaction.id }

      response '200', 'recurring transaction retrieved' do
        schema '$ref' => '#/components/schemas/RecurringTransaction'

        run_test!
      end

      response '401', 'unauthorized' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { nil }

        run_test!
      end

      response '404', 'recurring transaction not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { SecureRandom.uuid }

        run_test!
      end
    end

    patch 'Update recurring transaction' do
      tags 'Recurring Transactions'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json'
      produces 'application/json'

      let(:id) { recurring_transaction.id }

      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        properties: {
          recurring_transaction: {
            type: :object,
            properties: {
              status: { type: :string, enum: %w[active inactive] },
              expected_day_of_month: { type: :integer, minimum: 1, maximum: 31 },
              next_expected_date: { type: :string, format: :date }
            }
          }
        }
      }
      let(:body) { { recurring_transaction: { status: 'inactive' } } }

      response '200', 'recurring transaction updated' do
        schema '$ref' => '#/components/schemas/RecurringTransaction'

        run_test!
      end

      response '401', 'unauthorized' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { nil }

        run_test!
      end

      response '403', 'forbidden - requires read_write scope' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { read_only_api_key.plain_key }

        run_test!
      end

      response '404', 'recurring transaction not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { SecureRandom.uuid }

        run_test!
      end

      response '422', 'validation error' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:body) { { recurring_transaction: { expected_day_of_month: 32 } } }

        run_test!
      end
    end

    delete 'Delete recurring transaction' do
      tags 'Recurring Transactions'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      let(:id) { recurring_transaction.id }

      response '200', 'recurring transaction deleted' do
        schema '$ref' => '#/components/schemas/SuccessMessage'

        run_test!
      end

      response '401', 'unauthorized' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { nil }

        run_test!
      end

      response '403', 'forbidden - requires read_write scope' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { read_only_api_key.plain_key }

        run_test!
      end

      response '404', 'recurring transaction not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { SecureRandom.uuid }

        run_test!
      end
    end
  end
end
