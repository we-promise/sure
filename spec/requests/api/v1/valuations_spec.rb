# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'API V1 Valuations', type: :request do
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
      balance: 10000,
      currency: 'USD',
      accountable: Investment.create!
    )
  end

  let!(:valuation_entry) do
    account.entries.create!(
      name: 'Investment Reconciliation',
      date: Date.current,
      amount: 10000,
      currency: 'USD',
      entryable: Valuation.new(
        kind: 'reconciliation'
      )
    )
  end

  let!(:valuation) { valuation_entry.entryable }
  let!(:valuation_id) { valuation_entry.id }

  path '/api/v1/valuations' do
    get 'List valuations' do
      tags 'Valuations'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'
      parameter name: :page, in: :query, type: :integer, required: false,
                description: 'Page number (default: 1)'
      parameter name: :per_page, in: :query, type: :integer, required: false,
                description: 'Items per page (default: 25, max: 100)'
      parameter name: :account_id, in: :query, required: false, description: 'Filter by account ID',
                schema: { type: :string, format: :uuid }
      parameter name: :start_date, in: :query, required: false,
                description: 'Filter valuations from this date',
                schema: { type: :string, format: :date }
      parameter name: :end_date, in: :query, required: false,
                description: 'Filter valuations until this date',
                schema: { type: :string, format: :date }

      response '200', 'valuations listed' do
        schema '$ref' => '#/components/schemas/ValuationCollection'

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

      response '422', 'invalid account filter' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:account_id) { 'not-a-uuid' }

        run_test!
      end
    end

    post 'Create valuation' do
      tags 'Valuations'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json'
      produces 'application/json'
      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        properties: {
          valuation: {
            type: :object,
            properties: {
              account_id: { type: :string, format: :uuid, description: 'Account ID (required)' },
              amount: { type: :number, description: 'Valuation amount (required)' },
              date: { type: :string, format: :date, description: 'Valuation date (required)' },
              notes: { type: :string, description: 'Additional notes' },
              upsert: {
                type: :boolean,
                description: 'Nested alternative to the top-level response-status flag. Top-level upsert takes precedence when both are provided.'
              }
            },
            required: %w[account_id amount date]
          },
          upsert: {
            type: :boolean,
            description: 'Response-status signal only. When true and a same-account same-date valuation exists before the request, the endpoint returns 200 OK instead of 201 Created. The underlying reconciliation write path is unchanged; this flag does not add duplicate-prevention or safe-retry guarantees beyond existing same-date reconciliation behavior.'
          }
        },
        required: %w[valuation]
      }

      let(:body) do
        {
          valuation: {
            account_id: account.id,
            amount: 15000.00,
            date: Date.current.to_s
          }
        }
      end

      response '201', 'valuation created' do
        schema '$ref' => '#/components/schemas/Valuation'

        run_test!
      end

      response '200', 'existing valuation upserted' do
        schema '$ref' => '#/components/schemas/Valuation'

        let(:body) do
          {
            upsert: true,
            valuation: {
              account_id: account.id,
              amount: 15000.00,
              date: Date.current.to_s
            }
          }
        end

        run_test!
      end

      response '422', 'validation error - missing account_id' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:body) do
          {
            valuation: {
              amount: 15000.00,
              date: Date.current.to_s
            }
          }
        end

        run_test!
      end

      response '422', 'validation error - missing amount' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:body) do
          {
            valuation: {
              account_id: account.id,
              date: Date.current.to_s
            }
          }
        end

        run_test!
      end

      response '422', 'validation error - missing date' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:body) do
          {
            valuation: {
              account_id: account.id,
              amount: 15000.00
            }
          }
        end

        run_test!
      end

      response '404', 'account not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:body) do
          {
            valuation: {
              account_id: SecureRandom.uuid,
              amount: 15000.00,
              date: Date.current.to_s
            }
          }
        end

        run_test!
      end
    end
  end

  path '/api/v1/valuations/{id}' do
    parameter name: :id, in: :path, type: :string, required: true, description: 'Valuation ID (entry ID)'

    get 'Retrieve a valuation' do
      tags 'Valuations'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      let(:id) { valuation_id }

      response '200', 'valuation retrieved' do
        schema '$ref' => '#/components/schemas/Valuation'

        run_test!
      end

      response '404', 'valuation not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { SecureRandom.uuid }

        run_test!
      end
    end

    patch 'Update a valuation' do
      tags 'Valuations'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json'
      produces 'application/json'

      let(:id) { valuation_id }

      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        properties: {
          valuation: {
            type: :object,
            properties: {
              amount: { type: :number, description: 'New valuation amount (must provide with date)' },
              date: { type: :string, format: :date, description: 'New valuation date (must provide with amount)' },
              notes: { type: :string, description: 'Additional notes' }
            }
          }
        }
      }

      response '200', 'valuation updated with notes' do
        schema '$ref' => '#/components/schemas/Valuation'

        let(:body) do
          {
            valuation: {
              notes: 'Quarterly valuation update'
            }
          }
        end

        run_test!
      end

      response '200', 'valuation updated with amount and date' do
        schema '$ref' => '#/components/schemas/Valuation'

        let(:body) do
          {
            valuation: {
              amount: 12000.00,
              date: (Date.current - 1.day).to_s
            }
          }
        end

        run_test!
      end

      response '422', 'validation error - only one of amount/date provided' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:body) do
          {
            valuation: {
              amount: 12000.00
            }
          }
        end

        run_test!
      end

      response '404', 'valuation not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { SecureRandom.uuid }
        let(:body) do
          {
            valuation: {
              notes: 'This will fail'
            }
          }
        end

        run_test!
      end
    end
  end
end
