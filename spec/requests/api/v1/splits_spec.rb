# frozen_string_literal: true

require 'swagger_helper'

# Documentation only. Behavioral coverage lives in
# test/controllers/api/v1/splits_controller_test.rb, per
# docs/llm-guides/api-endpoint-consistency.md.
RSpec.describe 'API V1 Transaction Split', type: :request do
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
      email: 'api-split-user@example.com',
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
      name: 'Checking Account',
      balance: 1000,
      currency: 'USD',
      accountable: Depository.create!
    )
  end

  let!(:transaction) do
    entry = account.entries.create!(
      name: 'Marketplace order',
      date: Date.current,
      amount: 100,
      currency: 'USD',
      entryable: Transaction.new
    )
    entry.transaction
  end

  let(:transaction_id) { transaction.id }

  let(:split_payload) do
    {
      split: {
        splits: [
          { name: 'Groceries portion', amount: '60.0' },
          { name: 'Household portion', amount: '40.0' }
        ]
      }
    }
  end

  path '/api/v1/transactions/{transaction_id}/split' do
    parameter name: :transaction_id, in: :path, type: :string,
              description: 'Transaction ID. A split child resolves to its parent.'

    post 'Split a transaction' do
      tags 'Transactions'
      security [ { apiKeyAuth: [] } ]
      description 'Splits a transaction into child transactions. The child amounts must sum ' \
                  'exactly to the parent amount, using the same sign convention the ' \
                  'transaction endpoints return. The parent becomes excluded from totals.'
      consumes 'application/json'
      produces 'application/json'
      parameter name: :split, in: :body, schema: { '$ref' => '#/components/schemas/SplitRequest' }

      let(:split) { split_payload }

      response '201', 'transaction split' do
        schema '$ref' => '#/components/schemas/Split'
        run_test!
      end

      response '422', 'amounts do not sum to the parent, or the transaction cannot be split' do
        let(:split) { { split: { splits: [ { name: 'Too small', amount: '1.0' } ] } } }
        run_test!
      end
    end

    get 'Retrieve a transaction split' do
      tags 'Transactions'
      security [ { apiKeyAuth: [] } ]
      description 'Returns the child transactions of a split.'
      produces 'application/json'

      response '200', 'split returned' do
        schema '$ref' => '#/components/schemas/Split'
        before { transaction.entry.split!([ { name: 'A', amount: 60 }, { name: 'B', amount: 40 } ]) }
        run_test!
      end

      response '404', 'transaction is not split' do
        run_test!
      end
    end

    patch 'Replace a transaction split' do
      tags 'Transactions'
      security [ { apiKeyAuth: [] } ]
      description 'Replaces the children of an existing split. The previous children are ' \
                  'destroyed, so anything set on them afterwards is not carried over. Send ' \
                  'each child in full, including its merchant_id and tag_ids. A child without a ' \
                  'merchant_id takes the parent\'s merchant.'
      consumes 'application/json'
      produces 'application/json'
      parameter name: :split, in: :body, schema: { '$ref' => '#/components/schemas/SplitRequest' }

      let(:split) { split_payload }

      response '200', 'split replaced' do
        schema '$ref' => '#/components/schemas/Split'
        before { transaction.entry.split!([ { name: 'A', amount: 70 }, { name: 'B', amount: 30 } ]) }
        run_test!
      end
    end

    delete 'Remove a transaction split' do
      tags 'Transactions'
      security [ { apiKeyAuth: [] } ]
      description 'Removes the children and restores the parent transaction.'

      response '204', 'split removed' do
        before { transaction.entry.split!([ { name: 'A', amount: 60 }, { name: 'B', amount: 40 } ]) }
        run_test!
      end

      response '404', 'transaction is not split' do
        run_test!
      end
    end
  end

  path '/api/v1/transactions/{transaction_id}/split/itemize' do
    parameter name: :transaction_id, in: :path, type: :string
    post 'Queue a receipt split proposal' do
      tags 'Transactions'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'
      description 'Queues receipt extraction on the interactive AI queue. Poll result_url until status is completed or failed. A completed proposal is never saved as a split automatically; review proposal.split before submitting it to the split endpoint. Requires AI consent and write access.'
      parameter name: :attachment_id, in: :query, type: :string, required: false
      response '202', 'proposal queued or terminal enqueue failure' do
        schema '$ref' => '#/components/schemas/ReceiptItemization'
        run_test!
      end
      response('401', 'unauthorized') { run_test! }
      response('403', 'AI unavailable or write access missing') { run_test! }
      response('404', 'transaction not found') { run_test! }
      response('422', 'no receipt or transaction cannot be split') { run_test! }
    end
  end

  path '/api/v1/transactions/{transaction_id}/split/itemization/{receipt_itemization_id}' do
    parameter name: :transaction_id, in: :path, type: :string
    parameter name: :receipt_itemization_id, in: :path, type: :string
    get 'Read a receipt split proposal' do
      tags 'Transactions'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'
      description 'Returns only a result requested by the authenticated user for this accessible transaction. Pending results omit proposal; failed results contain a generic error without receipt text.'
      response '200', 'pending, completed or failed proposal' do
        schema '$ref' => '#/components/schemas/ReceiptItemization'
        run_test!
      end
      response('401', 'unauthorized') { run_test! }
      response('404', 'transaction or result not found') { run_test! }
    end
  end
end
