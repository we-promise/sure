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
                  '`idempotency_key` returns the transfer it already created (200) instead of a duplicate. ' \
                  'Send each value as the type its field has: ids and the key as UUID strings, amounts as numbers or ' \
                  'numeric strings, the date as `YYYY-MM-DD`. A value of the wrong type, such as an array or a boolean, ' \
                  'is rejected with a 422 instead of being ignored; null means the field was not sent (so does an empty string ' \
                  'for an amount, a rate or the date, but not for an id or the idempotency_key). ' \
                  'A number with more than 15 digits has to be sent as a string, because a JSON number cannot carry it exactly.'
      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        properties: {
          transfer: {
            type: :object,
            properties: {
              from_account_id: { type: :string, format: :uuid, description: 'Source account (required)' },
              to_account_id: { type: :string, format: :uuid, description: 'Destination account (required)' },
              amount: { oneOf: [ { type: :number }, { type: :string } ], description: 'Positive amount, as a number or a numeric string with at most 4 decimal places, in the source account\'s currency (required)' },
              date: { type: :string, format: :date, nullable: true, description: 'Defaults to today. A retry with an idempotency_key that leaves the date out matches the transfer made on an earlier day.' },
              exchange_rate: {
                anyOf: [ { type: :number, nullable: true }, { type: :string, nullable: true } ],
                description: 'Greater than 0. Source-to-destination rate. Only for accounts in different currencies; refused otherwise. A retry that leaves it out matches the transfer whichever rate it used.'
              },
              source_fee_amount: {
                anyOf: [ { type: :number, nullable: true }, { type: :string, nullable: true } ],
                description: 'Zero or more, at most 4 decimal places'
              },
              destination_fee_amount: {
                anyOf: [ { type: :number, nullable: true }, { type: :string, nullable: true } ],
                description: 'Zero or more, at most 4 decimal places'
              },
              tag_ids: { type: :array, nullable: true, items: { type: :string, format: :uuid }, description: 'Ids of tags in the family. Unknown ids are rejected.' },
              idempotency_key: { type: :string, format: :uuid, nullable: true, description: 'Makes retries safe. Reusing it with different values returns 409.' }
            },
            required: %w[from_account_id to_account_id amount]
          }
        },
        required: %w[transfer]
      }

      let(:idempotency_key) { SecureRandom.uuid }
      let(:amount) { 125 }
      let(:body) do
        {
          transfer: {
            from_account_id: checking.id,
            to_account_id: savings.id,
            amount: amount,
            date: Date.current.to_s,
            idempotency_key: idempotency_key
          }
        }
      end
      # A transfer already booked under idempotency_key, for the replay and conflict examples.
      let(:existing_transfer) do
        Transfer::Creator.new(
          family: family,
          source_account_id: checking.id,
          destination_account_id: savings.id,
          date: Date.current,
          amount: 125,
          idempotency_key: idempotency_key
        ).create
      end

      response '201', 'transfer created' do
        schema '$ref' => '#/components/schemas/TransferDecision'

        run_test!
      end

      response '200', 'idempotent replay: the transfer already created for this idempotency_key' do
        schema '$ref' => '#/components/schemas/TransferDecision'

        before { existing_transfer }

        run_test!
      end

      response '401', 'unauthorized' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { nil }

        run_test!
      end

      response '403', 'insufficient scope, or the key belongs to a guest' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { api_key_without_read_scope.plain_key }

        run_test!
      end

      response '400', 'missing transfer parameter' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:body) { {} }

        run_test!
      end

      response '404', 'account not found, not writable, or disabled' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:body) { { transfer: { from_account_id: checking.id, to_account_id: SecureRandom.uuid, amount: 10 } } }

        run_test!
      end

      response '409', 'idempotency_key was already used for a different transfer' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:amount) { 999 }

        before { existing_transfer }

        run_test!
      end

      response '422', 'validation error' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:amount) { 0 }

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
