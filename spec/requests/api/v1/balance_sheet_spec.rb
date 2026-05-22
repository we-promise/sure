# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'API V1 Balance Sheet', type: :request do
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

  path '/api/v1/balance_sheet' do
    get 'Show balance sheet' do
      tags 'Balance Sheet'
      description 'Returns the family balance sheet including net worth, total assets, and total liabilities ' \
                  'with amounts converted to the family\'s primary currency.'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      response '200', 'balance sheet returned' do
        schema '$ref' => '#/components/schemas/BalanceSheet'

        run_test!
      end

      response '401', 'unauthorized' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { 'invalid-key' }

        run_test!
      end
    end
  end
end
