# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'API V1 Financial Summary', type: :request do
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

  path '/api/v1/financial_summary' do
    get 'Show monthly financial summary' do
      tags 'Financial Summary'
      description 'Server-calculated income, spending, savings, and daily cumulative comparison in family currency. Uses the authenticated user’s finance accounts and Sure reporting rules.'
      parameter name: :month, in: :query, required: false, schema: { type: :string, format: :date }, description: 'Non-future first day YYYY-MM-01; defaults to the current month in the family time zone.'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      response '200', 'summary returned' do
        schema '$ref' => '#/components/schemas/FinancialSummary'

        run_test!
      end

      response '422', 'invalid month' do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        let(:month) { 'invalid' }
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
