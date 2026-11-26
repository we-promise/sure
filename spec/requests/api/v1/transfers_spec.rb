# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'API V1 Transfers', type: :request do
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
      display_key: key,
      scopes: [],
      source: 'mobile'
    ).tap { |api_key| api_key.save!(validate: false) }
  end

  let(:'X-Api-Key') { api_key.plain_key }
  let(:checking) { family.accounts.create!(owner: user, name: 'Checking', balance: 1000, currency: 'USD', accountable: Depository.create!) }
  let(:savings) { family.accounts.create!(owner: user, name: 'Savings', balance: 2500, currency: 'USD', accountable: Depository.create!) }
  let!(:outflow_entry) do
    checking.entries.create!(
      date: Date.current,
      amount: 100,
      name: 'Transfer to savings',
      currency: 'USD',
      entryable: Transaction.new(kind: 'funds_movement')
    )
  end
  let!(:inflow_entry) do
    savings.entries.create!(
      date: Date.current,
      amount: -100,
      name: 'Transfer from checking',
      currency: 'USD',
      entryable: Transaction.new(kind: 'funds_movement')
    )
  end
  let!(:transfer) do
    Transfer.create!(
      outflow_transaction: outflow_entry.entryable,
      inflow_transaction: inflow_entry.entryable,
      status: 'confirmed',
      notes: 'Confirmed by user'
    )
  end

  path '/api/v1/transfers' do
    get 'List transfers' do
      tags 'Transfers'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'
      parameter name: :page, in: :query, type: :integer, required: false,
                description: 'Page number (default: 1)'
      parameter name: :per_page, in: :query, type: :integer, required: false,
                description: 'Items per page (default: 25, max: 100)'
      parameter name: :status, in: :query, required: false,
                schema: { type: :string, enum: %w[pending confirmed] },
                description: 'Filter by transfer status'
      parameter name: :account_id, in: :query, required: false,
                schema: { type: :string, format: :uuid },
                description: 'Filter transfers involving this account'
      parameter name: :start_date, in: :query, required: false,
                schema: { type: :string, format: :date },
                description: 'Filter transfers from this date'
      parameter name: :end_date, in: :query, required: false,
                schema: { type: :string, format: :date },
                description: 'Filter transfers until this date'

      response '200', 'transfers listed' do
        schema '$ref' => '#/components/schemas/TransferDecisionCollection'

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

        let(:status) { 'settled' }

        run_test!
      end
    end
  end

  path '/api/v1/transfers' do
    post 'Create a transfer' do
      tags 'Transfers'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json'
      produces 'application/json'
      description 'Moves money between two accounts the API key\'s user can write to, booking both legs ' \
                  'as the web form does. Requires the read_write scope. Repeating a request with the same ' \
                  '`idempotency_key` returns the transfer it already created (200) instead of a duplicate.'
      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        properties: {
          transfer: {
            type: :object,
            properties: {
              from_account_id: { type: :string, format: :uuid, description: 'Source account (required)' },
              to_account_id: { type: :string, format: :uuid, description: 'Destination account (required)' },
              amount: { type: :number, description: 'Positive amount, in the source account\'s currency (required)' },
              date: { type: :string, format: :date, description: 'Defaults to today' },
              exchange_rate: { type: :number, description: 'Source-to-destination rate when the currencies differ' },
              source_fee_amount: { type: :number },
              destination_fee_amount: { type: :number },
              tag_ids: { type: :array, items: { type: :string, format: :uuid } },
              idempotency_key: { type: :string, format: :uuid, description: 'Makes retries safe' }
            },
            required: %w[from_account_id to_account_id amount]
          }
        },
        required: %w[transfer]
      }

      let(:body) do
        {
          transfer: {
            from_account_id: checking.id,
            to_account_id: savings.id,
            amount: 125.00,
            date: Date.current.to_s
          }
        }
      end

      response '201', 'transfer created' do
        schema '$ref' => '#/components/schemas/TransferDecision'

        run_test!
      end

      response '200', 'idempotent replay: the transfer already created for this idempotency_key' do
        schema '$ref' => '#/components/schemas/TransferDecision'

        let(:idempotency_key) { SecureRandom.uuid }
        let(:body) do
          {
            transfer: {
              from_account_id: checking.id,
              to_account_id: savings.id,
              amount: 125.00,
              date: Date.current.to_s,
              idempotency_key: idempotency_key
            }
          }
        end

        before do
          Transfer::Creator.new(
            family: family,
            source_account_id: checking.id,
            destination_account_id: savings.id,
            date: Date.current,
            amount: 125,
            idempotency_key: idempotency_key
          ).create
        end

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

      response '404', 'account not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:body) { { transfer: { from_account_id: checking.id, to_account_id: SecureRandom.uuid, amount: 10 } } }

        run_test!
      end

      response '422', 'validation error' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:body) { { transfer: { from_account_id: checking.id, to_account_id: savings.id, amount: 0 } } }

        run_test!
      end
    end
  end

  path '/api/v1/transfers/{id}' do
    parameter name: :id, in: :path, type: :string, required: true, description: 'Transfer ID'

    get 'Retrieve a transfer' do
      tags 'Transfers'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      let(:id) { transfer.id }

      response '200', 'transfer retrieved' do
        schema '$ref' => '#/components/schemas/TransferDecision'

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body['source_fee_amount']).to eq '0.0'
          expect(body['destination_fee_amount']).to eq '0.0'
          expect(body).to have_key('source_fee_currency')
          expect(body).to have_key('destination_fee_currency')
        end
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

      response '404', 'transfer not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { SecureRandom.uuid }

        run_test!
      end
    end
  end
end
