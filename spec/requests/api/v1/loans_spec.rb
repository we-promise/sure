# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'API V1 Loans', type: :request do
  let(:family) do
    Family.create!(
      name: 'Loan API Family',
      currency: 'USD',
      locale: 'en',
      date_format: '%m-%d-%Y'
    )
  end

  let(:user) do
    family.users.create!(
      email: 'loan-api-user@example.com',
      password: 'password123',
      password_confirmation: 'password123'
    )
  end

  let(:api_key) do
    key = ApiKey.generate_secure_key
    ApiKey.create!(
      user: user,
      name: 'Loan API Key',
      key: key,
      scopes: %w[read_write],
      source: 'web'
    )
  end

  let(:'X-Api-Key') { api_key.plain_key }

  let!(:mortgage_account) do
    Account.create!(
      family: family,
      name: 'Mortgage',
      balance: 500000,
      currency: 'USD',
      accountable: Loan.create!(
        subtype: 'mortgage',
        interest_rate: 3.5,
        term_months: 360,
        rate_type: 'fixed'
      )
    )
  end

  let!(:variable_loan_account) do
    Account.create!(
      family: family,
      name: 'Variable Rate Loan',
      balance: 500000,
      currency: 'USD',
      accountable: Loan.create!(
        subtype: 'line_of_credit',
        interest_rate: 3.5,
        term_months: 360,
        rate_type: 'variable'
      )
    )
  end

  path '/api/v1/accounts/{account_id}/amortization_schedule' do
    parameter name: :account_id, in: :path, required: true, description: 'Loan Account ID',
              schema: { type: :string, format: :uuid }
    parameter name: :page, in: :query, type: :integer, required: false,
              description: 'Page number (default: 1)'
    parameter name: :per_page, in: :query, type: :integer, required: false,
              description: 'Items per page (default: 25, max: 100)'

    get 'Get amortization schedule' do
      tags 'Loans'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      let(:account_id) { mortgage_account.id }

      response '200', 'amortization schedule retrieved' do
        schema '$ref' => '#/components/schemas/AmortizationScheduleResponse'

        run_test!
      end

      response '200', 'amortization schedule paginated' do
        schema '$ref' => '#/components/schemas/AmortizationScheduleResponse'

        let(:page) { 1 }
        let(:per_page) { 12 }

        run_test!
      end

      response '401', 'unauthorized' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { nil }

        run_test!
      end

      response '403', 'insufficient permissions' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:account_id) { SecureRandom.uuid }

        run_test!
      end

      response '404', 'account not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:account_id) { SecureRandom.uuid }

        run_test!
      end

      response '422', 'loan not amortizable' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:account_id) { variable_loan_account.id }

        run_test!
      end
    end
  end
end
