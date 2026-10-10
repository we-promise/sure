# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'API V1 Monthly Spending', type: :request do
  let(:family) { Family.create!(name: 'Monthly API Family', currency: 'USD', locale: 'en', date_format: '%m-%d-%Y') }
  let(:user) { family.users.create!(email: 'monthly-api@example.com', password: 'password123', preferences: { 'preview_features_enabled' => true }) }
  let(:api_key) { ApiKey.create!(user: user, name: 'API Docs Key', key: ApiKey.generate_secure_key, scopes: %w[read_write], source: 'web') }
  let(:'X-Api-Key') { api_key.plain_key }

  path '/api/v1/monthly_spending' do
    get 'Show monthly gross spending by root category (preview)' do
      tags 'Cash Flow'
      description 'Shared web/mobile aggregation in family currency for the authenticated user’s eligible finance accounts. Decimal strings; missing FX uses the existing 1:1 fallback and explicitly marks affected results as provisional. Transfers, pending entries and excluded entries are omitted. Refunds remain income. Requires personal preview access. Older servers may return 404.'
      parameter name: :from, in: :query, required: false, schema: { type: :string, format: :date }, description: 'First month YYYY-MM-01; defaults to 11 months before to. Maximum 36 months inclusive.'
      parameter name: :to, in: :query, required: false, schema: { type: :string, format: :date }, description: 'Last month YYYY-MM-01; defaults to current family-timezone month, capped at today. Future months are rejected.'
      parameter name: :'account_ids[]', in: :query, required: false, schema: { type: :array, items: { type: :string } }, description: 'Omitted means all eligible accounts. Send an empty-string item for explicit none. Unknown or unavailable IDs return 422.'
      parameter name: :'category_ids[]', in: :query, required: false, schema: { type: :array, items: { type: :string } }, description: 'Root category IDs (include children) or __uncategorized__. Omitted means all; empty-string item means none. Unknown IDs return 422.'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      response '200', 'monthly spending returned' do
        schema '$ref' => '#/components/schemas/MonthlySpending'
        run_test!
      end
      response '401', 'unauthorized' do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        let(:'X-Api-Key') { 'invalid-key' }
        run_test!
      end
      response '403', 'preview disabled' do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        let(:user) { family.users.create!(email: 'monthly-api@example.com', password: 'password123') }
        run_test!
      end
      response '422', 'invalid selection' do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        let(:from) { 'invalid' }
        run_test!
      end
    end
  end
end
