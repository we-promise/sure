# frozen_string_literal: true

require 'swagger_helper'

# Documentation only. Behavioral coverage lives in
# test/controllers/api/v1/transaction_auto_categorizations_controller_test.rb,
# per docs/llm-guides/api-endpoint-consistency.md.
RSpec.describe 'API V1 Transaction Auto-Categorization', type: :request do
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
      email: 'api-auto-categorize-user@example.com',
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

  let(:account) do
    Account.create!(
      family: family,
      owner: user,
      name: 'Checking Account',
      balance: 1000,
      currency: 'USD',
      accountable: Depository.create!
    )
  end

  let!(:transaction) do
    entry = account.entries.create!(
      name: 'Corner cafe',
      date: Date.current,
      amount: 12,
      currency: 'USD',
      entryable: Transaction.new
    )
    entry.transaction
  end

  before do
    family.categories.create!(name: 'Food & Drink', color: '#4da568', lucide_icon: 'utensils')
    allow_any_instance_of(Family).to receive(:resolved_categorization_provider).and_return(Object.new)
  end

  path '/api/v1/transactions/auto_categorize' do
    post 'Auto-categorize transactions with AI' do
      tags 'Transactions'
      security [ { apiKeyAuth: [] } ]
      description 'Queues AI categorization in the background using the family\'s configured ' \
                  'categorization provider and confidence threshold, as the "Auto-categorize ' \
                  'transactions with AI" rule action does. Only uncategorized transactions ' \
                  'without a locked (user-set) category are queued; transfers between the ' \
                  'family\'s own accounts and split parents are skipped. A 202 means the jobs ' \
                  'were queued, not that categories were assigned. A job can fail or the ' \
                  'provider can return no confident match, leaving a transaction ' \
                  'uncategorized. Read transactions back to see the result.'
      consumes 'application/json'
      produces 'application/json'
      parameter name: :body, in: :body, required: false,
                schema: { '$ref' => '#/components/schemas/TransactionAutoCategorizationRequest' }

      let(:body) { { transaction_ids: [ transaction.id ] } }

      response '202', 'categorization queued' do
        schema '$ref' => '#/components/schemas/TransactionAutoCategorization'
        run_test!
      end

      response '422', 'no categorization provider is configured, the family has no categories, ' \
                      'or transaction_ids is invalid' do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        let(:body) { { transaction_ids: [ 'not-a-uuid' ] } }
        run_test!
      end

      response '503', 'the job queue refused some or all of the batch' do
        schema '$ref' => '#/components/schemas/TransactionAutoCategorizationPartial'
        before do
          allow_any_instance_of(Family).to receive(:queue_auto_categorization)
            .and_return([ [], [ transaction.id ] ])
        end
        run_test!
      end
    end
  end
end
