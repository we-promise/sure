# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'API V1 Rule Runs', type: :request do
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

  let(:api_key_without_read_scope) do
    key = ApiKey.generate_secure_key
    # Valid persisted API keys can only be read/read_write; this intentionally
    # bypasses validations to document the runtime insufficient-scope response.
    ApiKey.new(
      user: user,
      name: 'No Read Docs Key',
      key: key,
      scopes: [],
      display_key: key,
      source: 'mobile'
    ).tap { |api_key| api_key.save!(validate: false) }
  end

  let(:'X-Api-Key') { api_key.plain_key }

  let!(:rule) do
    family.rules.build(
      name: 'Coffee cleanup',
      resource_type: 'transaction',
      active: true,
      effective_date: Date.new(2024, 1, 1)
    ).tap do |record|
      record.conditions.build(condition_type: 'transaction_name', operator: 'like', value: 'coffee')
      record.actions.build(action_type: 'set_transaction_name', value: 'Coffee')
      record.save!
    end
  end

  let!(:rule_run) do
    rule.rule_runs.create!(
      rule_name: rule.name,
      execution_type: 'manual',
      status: 'success',
      transactions_queued: 10,
      transactions_processed: 10,
      transactions_modified: 4,
      pending_jobs_count: 0,
      executed_at: Time.zone.parse('2024-01-15 12:00:00')
    )
  end

  path '/api/v1/rule_runs' do
    get 'List rule runs' do
      description 'List rule run history for the authenticated user family.'
      tags 'Rule Runs'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'
      parameter name: :page, in: :query, type: :integer, required: false,
                description: 'Page number (default: 1)'
      parameter name: :per_page, in: :query, type: :integer, required: false,
                description: 'Items per page (default: 25, max: 100)'
      parameter name: :rule_id, in: :query, required: false,
                description: 'Filter by rule ID',
                schema: { type: :string, format: :uuid }
      parameter name: :status, in: :query, required: false,
                description: 'Filter by run status',
                schema: { type: :string, enum: %w[pending success failed] }
      parameter name: :execution_type, in: :query, required: false,
                description: 'Filter by execution type',
                schema: { type: :string, enum: %w[manual scheduled] }
      parameter name: :start_executed_at, in: :query, required: false,
                description: 'Filter runs executed at or after this timestamp',
                schema: { type: :string, format: :'date-time' }
      parameter name: :end_executed_at, in: :query, required: false,
                description: 'Filter runs executed at or before this timestamp',
                schema: { type: :string, format: :'date-time' }

      response '200', 'rule runs listed' do
        schema '$ref' => '#/components/schemas/RuleRunCollection'

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

        let(:status) { 'unknown' }

        run_test!
      end
    end
  end

  path '/api/v1/rule_runs/{id}' do
    parameter name: :id, in: :path, required: true, description: 'Rule run ID',
              schema: { type: :string, format: :uuid }

    get 'Retrieve a rule run' do
      description 'Retrieve one rule run from the authenticated user family.'
      tags 'Rule Runs'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      let(:id) { rule_run.id }

      response '200', 'rule run retrieved' do
        schema '$ref' => '#/components/schemas/RuleRunResponse'

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

      response '404', 'rule run not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { SecureRandom.uuid }

        run_test!
      end
    end
  end
end
