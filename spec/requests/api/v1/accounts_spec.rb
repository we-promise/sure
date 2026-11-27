# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'API V1 Accounts', type: :request do
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
    # Valid persisted API keys can only be read/read_write; this intentionally
    # bypasses validations to document the runtime insufficient-scope response.
    ApiKey.new(
      user: user,
      name: 'No Read Docs Key',
      key: key,
      display_key: key,
      scopes: %w[write],
      source: 'web'
    ).tap { |api_key| api_key.save!(validate: false) }
  end

  let(:'X-Api-Key') { api_key.plain_key }

  let!(:checking_account) do
    Account.create!(
      family: family,
      owner: user,
      name: 'Checking Account',
      balance: 1500.50,
      currency: 'USD',
      accountable: Depository.create!
    )
  end

  let!(:savings_account) do
    Account.create!(
      family: family,
      owner: user,
      name: 'Savings Account',
      balance: 10000.00,
      currency: 'USD',
      accountable: Depository.create!
    )
  end

  let!(:credit_card) do
    Account.create!(
      family: family,
      owner: user,
      name: 'Credit Card',
      balance: -500.00,
      currency: 'USD',
      accountable: CreditCard.create!
    )
  end

  path '/api/v1/accounts' do
    get 'List accounts' do
      tags 'Accounts'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'
      parameter name: :page, in: :query, type: :integer, required: false,
                description: 'Page number (default: 1)'
      parameter name: :per_page, in: :query, type: :integer, required: false,
                description: 'Items per page (default: 25, max: 100)'
      parameter name: :include_disabled, in: :query, type: :boolean, required: false,
                description: 'Include disabled accounts in the response. Defaults to false.'

      response '200', 'accounts listed' do
        schema '$ref' => '#/components/schemas/AccountCollection'

        run_test!
      end

      response '200', 'accounts paginated' do
        schema '$ref' => '#/components/schemas/AccountCollection'

        let(:page) { 1 }
        let(:per_page) { 2 }

        run_test!
      end
    end
  end

  path '/api/v1/accounts' do
    post 'Create an account' do
      tags 'Accounts'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json'
      produces 'application/json'
      description 'Creates an account owned by the API key\'s user and records its opening balance. ' \
                  'Requires the read_write scope. For a loan, send `accountable_attributes.initial_balance` ' \
                  '(original principal) and `start_date` to anchor the opening balance on the day it was drawn; ' \
                  '`balance` is the current amount owed. Send each value as the type its field has: text as a string, ' \
                  'numbers as numbers or numeric strings, dates as `YYYY-MM-DD` and flags as true or false. ' \
                  'A value of the wrong type, or a number with more decimal places than the field keeps, is rejected with a ' \
                  '422 instead of being converted or rounded; null or an empty string means the field was not sent. ' \
                  'A number with more than 15 digits has to be sent as a string, because a JSON number cannot carry it exactly.'
      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        properties: {
          account: {
            type: :object,
            properties: {
              name: { type: :string, description: 'Account name (required)' },
              accountable_type: {
                type: :string,
                enum: Accountable::TYPES.map(&:underscore) + Accountable::TYPES,
                description: 'Account type (required). CamelCase names such as CreditCard are also accepted.'
              },
              balance: {
                oneOf: [ { type: :number }, { type: :string } ],
                description: 'Current balance (required), as a number or a numeric string. For liabilities, the amount owed.'
              },
              currency: { type: :string, nullable: true, description: 'ISO 4217 code. Defaults to the family currency.' },
              subtype: { type: :string, nullable: true, description: 'Account subtype. Must be one of the subtypes of the accountable_type, otherwise the request is rejected.' },
              opening_balance_date: {
                type: :string, format: :date, nullable: true,
                description: 'Date of the opening balance. Defaults to two years ago; a loan\'s start_date takes precedence.'
              },
              institution_name: { type: :string, nullable: true },
              institution_domain: { type: :string, nullable: true },
              notes: { type: :string, nullable: true },
              exclude_from_reports: { type: :boolean, nullable: true },
              accountable_attributes: {
                type: :object, nullable: true,
                description: 'Type-specific attributes, the same ones the web form accepts (for a loan: ' \
                             'initial_balance, start_date, interest_rate, rate_type, term_months, ...). ' \
                             'Must be an object. A `subtype` here must match the one on the account, if both are sent.',
                additionalProperties: true
              }
            },
            required: %w[name accountable_type balance]
          }
        },
        required: %w[account]
      }

      let(:body) do
        {
          account: {
            name: 'Car Lease',
            accountable_type: 'loan',
            balance: 48_000.00,
            currency: 'USD',
            accountable_attributes: {
              initial_balance: 51_000.00,
              start_date: '2026-06-03',
              interest_rate: 6.5,
              rate_type: 'fixed',
              term_months: 36
            }
          }
        }
      end

      response '201', 'account created' do
        schema '$ref' => '#/components/schemas/AccountDetail'

        run_test!
      end

      response '401', 'unauthorized' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { nil }

        run_test!
      end

      response '400', 'missing account parameter' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:body) { {} }

        run_test!
      end

      response '403', 'insufficient scope, or the key belongs to a guest' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { api_key_without_read_scope.plain_key }

        run_test!
      end

      response '422', 'validation error' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:body) { { account: { name: 'No type', balance: 1 } } }

        run_test!
      end
    end
  end

  path '/api/v1/accounts/{id}' do
    parameter name: :id, in: :path, required: true, description: 'Account ID',
              schema: { type: :string, format: :uuid }

    get 'Retrieve an account' do
      tags 'Accounts'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'
      parameter name: :include_disabled, in: :query, type: :boolean, required: false,
                description: 'Allow retrieving a disabled account. Defaults to false.'

      let(:id) { checking_account.id }

      response '200', 'account retrieved' do
        schema '$ref' => '#/components/schemas/AccountDetail'

        run_test!
      end

      response '401', 'unauthorized' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { checking_account.id }
        let(:'X-Api-Key') { nil }

        run_test!
      end

      response '403', 'insufficient scope' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { checking_account.id }
        let(:'X-Api-Key') { api_key_without_read_scope.plain_key }

        run_test!
      end

      response '404', 'account not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { SecureRandom.uuid }

        run_test!
      end
    end
  end
end
