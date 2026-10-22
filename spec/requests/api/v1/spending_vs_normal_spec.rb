# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'API V1 Spending vs Normal', type: :request do
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
      scopes: %w[read],
      source: 'web'
    )
  end

  let(:'X-Api-Key') { api_key.plain_key }

  path '/api/v1/spending_vs_normal' do
    get 'Show spending per category against normal' do
      tags 'Reports'
      description 'Net spending per category in a period, compared with each category\'s normal. For a finished period, normal is its net spending over the year before the period, scaled to the period length. An unfinished period (in_progress) is cut to today and compared with the average of the same number of days from each of up to 12 earlier month starts, counting only windows that end before the period. The data behind the Reports section "Spending vs normal". Uses the authenticated user\'s finance accounts and Sure reporting rules. Experimental: the section is a preview feature, and how normal is defined may still change.'
      parameter name: :start_date, in: :query, required: false, schema: { type: :string, format: :date }, description: 'Inclusive ISO date. Requires end_date; both omitted means the current month to date.'
      parameter name: :end_date, in: :query, required: false, schema: { type: :string, format: :date }, description: 'Inclusive ISO date at or after start_date.'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      response '200', 'comparison returned' do
        schema '$ref' => '#/components/schemas/SpendingVsNormal'

        run_test!
      end

      response '422', 'invalid period' do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        let(:start_date) { '2024-03-01' }
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
