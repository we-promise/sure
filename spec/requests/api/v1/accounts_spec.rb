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

  let(:'X-Api-Key') { api_key.plain_key }

  let!(:checking_account) do
    Account.create!(
      family: family,
      name: 'Checking Account',
      balance: 1500.50,
      currency: 'USD',
      accountable: Depository.create!
    )
  end

  let!(:savings_account) do
    Account.create!(
      family: family,
      name: 'Savings Account',
      balance: 10000.00,
      currency: 'USD',
      accountable: Depository.create!
    )
  end

  let!(:credit_card) do
    Account.create!(
      family: family,
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

    post 'Create an account' do
      tags 'Accounts'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json'
      produces 'application/json'
      parameter name: :account, in: :body, schema: {
        type: :object,
        properties: {
          account: {
            type: :object,
            required: %w[name accountable_type],
            properties: {
              name: { type: :string, description: 'Account name' },
              accountable_type: { type: :string, description: 'Account type (e.g. Depository, CreditCard, Investment)' },
              balance: { type: :number, description: 'Initial balance (default: 0)' },
              currency: { type: :string, description: 'Currency code (default: family currency)' },
              subtype: { type: :string, description: 'Account subtype' }
            }
          }
        }
      }

      response '201', 'account created' do
        let(:account) { { account: { name: 'New Savings', accountable_type: 'Depository', balance: 1000, currency: 'USD' } } }

        run_test!
      end

      response '422', 'validation failed' do
        let(:account) { { account: { accountable_type: 'Depository' } } }

        run_test!
      end
    end
  end

  path '/api/v1/accounts/{id}' do
    parameter name: :id, in: :path, type: :string, required: true, description: 'Account ID'

    get 'Retrieve an account' do
      tags 'Accounts'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      response '200', 'account retrieved' do
        let(:id) { checking_account.id }

        run_test!
      end

      response '404', 'account not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { SecureRandom.uuid }

        run_test!
      end
    end

    patch 'Update an account' do
      tags 'Accounts'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json'
      produces 'application/json'
      parameter name: :account, in: :body, schema: {
        type: :object,
        properties: {
          account: {
            type: :object,
            properties: {
              name: { type: :string, description: 'Account name' },
              balance: { type: :number, description: 'Current balance' }
            }
          }
        }
      }

      response '200', 'account updated' do
        let(:id) { checking_account.id }
        let(:account) { { account: { name: 'Updated Checking' } } }

        run_test!
      end

      response '404', 'account not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { SecureRandom.uuid }
        let(:account) { { account: { name: 'Not Found' } } }

        run_test!
      end
    end

    delete 'Delete an account' do
      tags 'Accounts'
      security [ { apiKeyAuth: [] } ]

      response '200', 'account deleted' do
        let(:id) { checking_account.id }

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
