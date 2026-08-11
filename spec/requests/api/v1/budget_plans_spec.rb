# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'API V1 Budget Plans', type: :request do
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
      display_key: key,
      scopes: %w[read_write],
      source: 'web'
    )
  end

  let(:read_only_api_key) do
    key = ApiKey.generate_secure_key
    ApiKey.create!(
      user: user,
      name: 'Read Only Docs Key',
      key: key,
      display_key: key,
      scopes: %w[read],
      source: 'web'
    )
  end

  let(:'X-Api-Key') { api_key.plain_key }

  let!(:budget_plan) { family.budget_plans.create!(name: 'Joint') }

  path '/api/v1/budget_plans' do
    get 'List budget plans' do
      tags 'Budget Plans'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      response '200', 'budget plans listed' do
        schema type: :array, items: { '$ref' => '#/components/schemas/BudgetPlan' }

        run_test!
      end

      response '401', 'unauthorized' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { nil }

        run_test!
      end
    end

    post 'Create a budget plan' do
      tags 'Budget Plans'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json'
      produces 'application/json'
      parameter name: :body, in: :body, schema: {
        type: :object,
        required: %w[budget_plan],
        properties: {
          budget_plan: {
            type: :object,
            required: %w[name],
            properties: {
              name: { type: :string },
              account_ids: {
                type: :array,
                items: { type: :string, format: :uuid },
                description: 'Accounts to scope the plan to; omit or send [] to track all accounts'
              }
            }
          }
        }
      }

      response '201', 'budget plan created' do
        schema '$ref' => '#/components/schemas/BudgetPlan'

        let(:body) { { budget_plan: { name: 'Personal' } } }

        run_test!
      end

      response '403', 'insufficient scope' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { read_only_api_key.plain_key }
        let(:body) { { budget_plan: { name: 'Personal' } } }

        run_test!
      end

      response '422', 'validation failed' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:body) { { budget_plan: { name: '' } } }

        run_test!
      end
    end
  end

  path '/api/v1/budget_plans/{id}' do
    parameter name: :id, in: :path, required: true, description: 'Budget plan ID',
              schema: { type: :string, format: :uuid }

    get 'Retrieve a budget plan' do
      tags 'Budget Plans'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      let(:id) { budget_plan.id }

      response '200', 'budget plan retrieved' do
        schema '$ref' => '#/components/schemas/BudgetPlan'

        run_test!
      end

      response '404', 'budget plan not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { SecureRandom.uuid }

        run_test!
      end
    end

    patch 'Update a budget plan' do
      tags 'Budget Plans'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json'
      produces 'application/json'
      parameter name: :body, in: :body, schema: {
        type: :object,
        required: %w[budget_plan],
        properties: {
          budget_plan: {
            type: :object,
            properties: {
              name: { type: :string },
              account_ids: {
                type: :array,
                items: { type: :string, format: :uuid },
                description: 'Replaces the plan\'s account scope; [] clears it back to all accounts. Omit to leave unchanged.'
              }
            }
          }
        }
      }

      let(:id) { budget_plan.id }

      response '200', 'budget plan updated' do
        schema '$ref' => '#/components/schemas/BudgetPlan'

        let(:body) { { budget_plan: { name: 'Renamed' } } }

        run_test!
      end
    end

    delete 'Delete a budget plan' do
      tags 'Budget Plans'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      let(:id) { budget_plan.id }

      response '204', 'budget plan deleted' do
        run_test!
      end

      response '422', 'cannot delete the default plan' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { family.default_budget_plan.id }

        run_test!
      end
    end
  end
end
