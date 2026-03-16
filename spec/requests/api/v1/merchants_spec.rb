# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'API V1 Merchants', type: :request do
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

  let!(:family_merchant) { family.merchants.create!(name: 'Coffee Shop') }

  path '/api/v1/merchants' do
    get 'List merchants' do
      tags 'Merchants'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      response '200', 'merchants listed' do
        schema type: :array, items: { '$ref' => '#/components/schemas/MerchantDetail' }

        run_test!
      end
    end
  end

  path '/api/v1/merchants/{id}' do
    parameter name: :id, in: :path, type: :string, required: true, description: 'Merchant ID'

    get 'Retrieve a merchant' do
      tags 'Merchants'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      response '200', 'merchant retrieved' do
        schema '$ref' => '#/components/schemas/MerchantDetail'

        let(:id) { family_merchant.id }

        run_test!
      end

      response '404', 'merchant not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { SecureRandom.uuid }

        run_test!
      end
    end
  end
end
