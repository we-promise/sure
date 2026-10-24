# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'API V1 Budget Categories', type: :request do
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

  let(:api_key_without_read_scope) do
    key = ApiKey.generate_secure_key
    ApiKey.new(
      user: user,
      name: 'No Read Docs Key',
      key: key,
      scopes: [],
      source: 'mobile'
    ).tap { |api_key| api_key.save!(validate: false) }
  end

  let(:'X-Api-Key') { api_key.plain_key }
  let!(:category) { family.categories.create!(name: 'Groceries', color: '#22c55e') }
  let!(:budget) do
    family.budgets.create!(
      start_date: Date.current.beginning_of_month,
      end_date: Date.current.end_of_month,
      budgeted_spending: 3000,
      expected_income: 5000,
      currency: 'USD'
    )
  end
  let!(:budget_category) do
    budget.budget_categories.create!(
      category: category,
      budgeted_spending: 500,
      currency: 'USD'
    )
  end

  path '/api/v1/budget_categories' do
    get 'List budget categories' do
      tags 'Budget Categories'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'
      parameter name: :page, in: :query, type: :integer, required: false,
                description: 'Page number (default: 1)'
      parameter name: :per_page, in: :query, type: :integer, required: false,
                description: 'Items per page (default: 25, max: 100)'
      parameter name: :budget_id, in: :query, required: false,
                schema: { type: :string, format: :uuid },
                description: 'Filter by budget ID'
      parameter name: :category_id, in: :query, required: false,
                schema: { type: :string, format: :uuid },
                description: 'Filter by category ID'
      parameter name: :start_date, in: :query, required: false,
                schema: { type: :string, format: :date },
                description: 'Filter budget categories whose budget starts on or after this date'
      parameter name: :end_date, in: :query, required: false,
                schema: { type: :string, format: :date },
                description: 'Filter budget categories whose budget ends on or before this date'

      response '200', 'budget categories listed' do
        schema '$ref' => '#/components/schemas/BudgetCategoryCollection'

        run_test!
      end

      response '401', 'unauthorized' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { nil }

        run_test!
      end

      response '403', 'insufficient scope' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { api_key_without_read_scope.plain_key }

        run_test!
      end

      response '422', 'invalid filter' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:budget_id) { 'not-a-uuid' }

        run_test!
      end
    end
  end

  path '/api/v1/budget_categories/{id}' do
    parameter name: :id, in: :path, required: true, description: 'Budget category ID',
              schema: { type: :string, format: :uuid }

    get 'Retrieve a budget category' do
      tags 'Budget Categories'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      let(:id) { budget_category.id }

      response '200', 'budget category retrieved' do
        schema '$ref' => '#/components/schemas/BudgetCategory'

        run_test!
      end

      response '401', 'unauthorized' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { nil }

        run_test!
      end

      response '403', 'insufficient scope' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { api_key_without_read_scope.plain_key }

        run_test!
      end

      response '404', 'budget category not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { SecureRandom.uuid }

        run_test!
      end
    end
  end
end
