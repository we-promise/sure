# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'API V1 Paycheck Plans', type: :request do
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
    ApiKey.new(
      user: user,
      name: 'No Read Docs Key',
      key: key,
      scopes: %w[write],
      source: 'web'
    ).tap do |api_key|
      # 'write' is not a valid scope, so the record is saved with validation
      # skipped. That also skips the before_validation that copies `key` into
      # `display_key`, and the column is NOT NULL — set it explicitly.
      api_key.display_key = key
      api_key.save!(validate: false)
    end
  end

  let(:other_family) do
    Family.create!(
      name: 'API Other Family',
      currency: 'USD',
      locale: 'en',
      date_format: '%m-%d-%Y'
    )
  end

  let(:other_user) do
    other_family.users.create!(
      email: 'api-other-user@example.com',
      password: 'password123',
      password_confirmation: 'password123'
    )
  end

  let(:other_api_key) do
    key = ApiKey.generate_secure_key
    ApiKey.create!(
      user: other_user,
      name: 'Other API Docs Key',
      key: key,
      scopes: %w[read_write],
      source: 'web'
    )
  end

  let(:'X-Api-Key') { api_key.plain_key }

  path '/api/v1/families/{id}/paycheck-plans' do
    parameter name: :id, in: :path, required: true, description: 'Family ID',
              schema: { type: :string, format: :uuid }

    get 'Retrieve the paycheck flow plan for a family and month' do
      tags 'Paycheck Plans'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'
      parameter name: :month, in: :query, required: false,
                description: 'Planner month as a YYYY-MM month (defaults to the current month)',
                schema: { type: :string }

      let(:id) { family.id }

      response '200', 'paycheck plan resolved' do
        schema type: :object, required: %w[month paycheck_dates total_paychecks accounts paychecks leftover_attribution delta suggested_fix shortfalls],
               properties: {
                 month: { type: :string, format: :date, description: 'First day of the planned month (YYYY-MM-DD)' },
                 paycheck_dates: {
                   type: :array,
                   description: 'Resolved pay dates inside the month, ascending',
                   items: { type: :string, format: :date }
                 },
                 total_paychecks: { type: :integer, minimum: 0, description: 'Number of paychecks in the month' },
                 accounts: {
                   type: :array,
                   description: 'Accounts the plan touches, with required obligations prorated over the month and the month total',
                   items: {
                     type: :object,
                     required: %w[id required_month required_per_paycheck total_in_month],
                     properties: {
                       id: { type: :string, format: :uuid },
                       required_month: { type: :string, description: 'Required obligations for the month (2-dp major units)' },
                       required_per_paycheck: { type: :string, description: 'Required obligations prorated per paycheck (2-dp major units)' },
                       total_in_month: { type: :string, description: 'Total resolved into the account over the month (2-dp major units)' }
                     }
                   }
                 },
                 paychecks: {
                   type: :array,
                   description: 'Per-paycheck resolution, in date order',
                   items: {
                     type: :object,
                     required: %w[date total_income allocations by_account],
                     properties: {
                       date: { type: :string, format: :date },
                       total_income: { type: :string, description: 'Gross arriving with this paycheck (2-dp major units)' },
                       allocations: {
                         type: :array,
                         description: 'Edge rows for this paycheck, in stream resolution order',
                         items: {
                           type: :object,
                           required: %w[income_series_id account_id mode amount],
                           properties: {
                             income_series_id: { type: :string, format: :uuid },
                             account_id: { type: :string, format: :uuid },
                             mode: { type: :string, enum: %w[required specific percent leftover] },
                             amount: { type: :string, description: '2-dp major units' },
                             shortfall: { type: :boolean, description: 'Present on the leftover row only; true when required and fixed allocations outran the paycheck' }
                           }
                         }
                       },
                       by_account: { type: :object, description: 'Account ID to 2-dp major-unit total for this paycheck', additionalProperties: { type: :string } }
                     }
                   }
                 },
                 leftover_attribution: {
                   type: :object,
                   required: %w[distribution pooled_per_paycheck pooled_month by_partner],
                   properties: {
                     distribution: { type: :string, enum: %w[income_ratio equal_split custom], description: 'Family leftover distribution mode' },
                     pooled_per_paycheck: { type: :string, description: 'Pooled leftover per paycheck (2-dp major units)' },
                     pooled_month: { type: :string, description: 'Pooled leftover for the month (2-dp major units)' },
                     by_partner: {
                       type: :array,
                       items: {
                         type: :object,
                         required: %w[user_id weight fun_money_per_paycheck fun_money_month actual_leftover_month],
                         properties: {
                           user_id: { type: :string, format: :uuid },
                           weight: { type: :string, description: 'Attribution weight (4-dp fraction)' },
                           fun_money_per_paycheck: { type: :string, description: '2-dp major units' },
                           fun_money_month: { type: :string, description: '2-dp major units' },
                           actual_leftover_month: { type: :string, description: 'Partner actual unassigned leftover for the month (2-dp major units)' }
                         }
                       }
                     }
                   }
                 },
                 delta: {
                   type: :object,
                   required: %w[target_month spread_month by_partner],
                   properties: {
                     target_month: { type: :string, description: 'Per-partner target leftover (2-dp major units)' },
                     spread_month: { type: :string, description: 'Max minus min of the partner deltas (2-dp major units)' },
                     by_partner: {
                       type: :array,
                       items: {
                         type: :object,
                         required: %w[user_id delta_month],
                         properties: {
                           user_id: { type: :string, format: :uuid },
                           delta_month: { type: :string, description: 'Partner actual leftover minus target (2-dp major units)' }
                         }
                       }
                     }
                   }
                 },
                 suggested_fix: {
                   type: :object,
                   nullable: true,
                   description: 'One-variable percent shift that lands the furthest-over-partner on target; null when not applicable',
                   properties: {
                     user_id: { type: :string, format: :uuid },
                     income_series_id: { type: :string, format: :uuid },
                     account_id: { type: :string, format: :uuid },
                     current_percent: { type: :string, description: '4-dp fraction' },
                     suggested_percent: { type: :string, description: '4-dp fraction' },
                     new_leftover_month: { type: :string, description: 'Projected leftover after the shift (2-dp major units)' }
                   }
                 },
                 shortfalls: {
                   type: :array,
                   description: 'Income series whose required and fixed allocations outran the month',
                   items: {
                     type: :object,
                     required: %w[income_series_id gap_month message],
                     properties: {
                       income_series_id: { type: :string, format: :uuid },
                       gap_month: { type: :string, description: 'Monthly gap (2-dp major units)' },
                       message: { type: :string, description: 'Human-readable shortfall notice for the month' }
                     }
                   }
                 }
               }

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

      response '403', 'not a member of this family' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { other_api_key.plain_key }

        run_test!
      end

      response '404', 'family not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { SecureRandom.uuid }

        run_test!
      end

      response '422', 'invalid month' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:month) { '2026-13' }

        run_test!
      end
    end
  end
end
