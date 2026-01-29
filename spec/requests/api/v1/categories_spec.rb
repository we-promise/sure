# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'API V1 Categories', type: :request do
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

  let!(:parent_category) do
    family.categories.create!(
      name: 'Food & Drink',
      classification: 'expense',
      color: '#f97316',
      lucide_icon: 'utensils'
    )
  end

  let!(:subcategory) do
    family.categories.create!(
      name: 'Restaurants',
      classification: 'expense',
      color: '#f97316',
      lucide_icon: 'utensils',
      parent: parent_category
    )
  end

  let!(:income_category) do
    family.categories.create!(
      name: 'Salary',
      classification: 'income',
      color: '#22c55e',
      lucide_icon: 'circle-dollar-sign'
    )
  end

  path '/api/v1/categories' do
    get 'List categories' do
      tags 'Categories'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'
      parameter name: :page, in: :query, type: :integer, required: false,
                description: 'Page number (default: 1)'
      parameter name: :per_page, in: :query, type: :integer, required: false,
                description: 'Items per page (default: 25, max: 100)'
      parameter name: :classification, in: :query, required: false,
                description: 'Filter by classification (income or expense)',
                schema: { type: :string, enum: %w[income expense] }
      parameter name: :roots_only, in: :query, required: false,
                description: 'Return only root categories (no parent)',
                schema: { type: :boolean }
      parameter name: :parent_id, in: :query, required: false,
                description: 'Filter by parent category ID',
                schema: { type: :string, format: :uuid }

      response '200', 'categories listed' do
        schema '$ref' => '#/components/schemas/CategoryCollection'

        run_test!
      end

      response '200', 'categories filtered by classification' do
        schema '$ref' => '#/components/schemas/CategoryCollection'

        let(:classification) { 'expense' }

        run_test!
      end

      response '200', 'root categories only' do
        schema '$ref' => '#/components/schemas/CategoryCollection'

        let(:roots_only) { true }

        run_test!
      end

      response '200', 'categories filtered by parent' do
        schema '$ref' => '#/components/schemas/CategoryCollection'

        let(:parent_id) { parent_category.id }

        run_test!
      end
    end
  end

  path '/api/v1/categories/{id}' do
    parameter name: :id, in: :path, type: :string, required: true, description: 'Category ID'

    get 'Retrieve a category' do
      tags 'Categories'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      let(:id) { parent_category.id }

      response '200', 'category retrieved' do
        schema '$ref' => '#/components/schemas/CategoryDetail'

        run_test!
      end

      response '200', 'subcategory retrieved with parent' do
        schema '$ref' => '#/components/schemas/CategoryDetail'

        let(:id) { subcategory.id }

        run_test!
      end

      response '404', 'category not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { SecureRandom.uuid }

        run_test!
      end
    end
  end
end
