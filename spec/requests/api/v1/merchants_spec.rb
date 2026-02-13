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

  let!(:amazon_merchant) do
    family.merchants.create!(name: 'Amazon', color: '#ff9900', website_url: 'https://amazon.com')
  end

  let!(:netflix_merchant) do
    family.merchants.create!(name: 'Netflix', color: '#e50914', website_url: 'https://netflix.com')
  end

  let!(:starbucks_merchant) do
    family.merchants.create!(name: 'Starbucks', color: '#00704a')
  end

  path '/api/v1/merchants' do
    get 'List merchants' do
      tags 'Merchants'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      response '200', 'merchants listed' do
        schema '$ref' => '#/components/schemas/MerchantCollection'

        run_test!
      end
    end

    post 'Create merchant' do
      tags 'Merchants'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json'
      produces 'application/json'
      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        properties: {
          merchant: {
            type: :object,
            properties: {
              name: { type: :string, description: 'Merchant name (required)' },
              color: { type: :string, description: 'Hex color code (optional, auto-assigned if not provided)' },
              website_url: { type: :string, description: 'Website URL (optional)' }
            },
            required: %w[name]
          }
        },
        required: %w[merchant]
      }

      response '201', 'merchant created' do
        schema '$ref' => '#/components/schemas/MerchantDetail'

        let(:body) do
          {
            merchant: {
              name: 'Walmart',
              color: '#0071ce',
              website_url: 'https://walmart.com'
            }
          }
        end

        run_test!
      end

      response '201', 'merchant created with auto-assigned color' do
        schema '$ref' => '#/components/schemas/MerchantDetail'

        let(:body) do
          {
            merchant: {
              name: 'Target'
            }
          }
        end

        run_test!
      end

      response '422', 'validation error - duplicate name' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:body) do
          {
            merchant: {
              name: 'Amazon'
            }
          }
        end

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

      let(:id) { amazon_merchant.id }

      response '200', 'merchant retrieved' do
        schema '$ref' => '#/components/schemas/MerchantDetail'

        run_test!
      end

      response '404', 'merchant not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { SecureRandom.uuid }

        run_test!
      end
    end

    patch 'Update a merchant' do
      tags 'Merchants'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json'
      produces 'application/json'

      let(:id) { amazon_merchant.id }

      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        properties: {
          merchant: {
            type: :object,
            properties: {
              name: { type: :string },
              color: { type: :string },
              website_url: { type: :string }
            }
          }
        }
      }

      let(:body) do
        {
          merchant: {
            name: 'Amazon Updated',
            color: '#232f3e'
          }
        }
      end

      response '200', 'merchant updated' do
        schema '$ref' => '#/components/schemas/MerchantDetail'

        run_test!
      end

      response '404', 'merchant not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { SecureRandom.uuid }

        run_test!
      end
    end

    delete 'Delete a merchant' do
      tags 'Merchants'
      security [ { apiKeyAuth: [] } ]

      let(:id) { starbucks_merchant.id }

      response '204', 'merchant deleted' do
        run_test!
      end

      response '404', 'merchant not found' do
        let(:id) { SecureRandom.uuid }

        run_test!
      end
    end
  end
end
