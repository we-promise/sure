# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'API V1 Import Sessions', type: :request do
  let(:user) { users(:empty) }
  let(:family) { user.family }

  let(:api_key) { api_keys(:active_key) }
  let(:api_key_without_write_scope) { api_keys(:one) }
  let(:api_key_without_read_scope) { api_keys(:expired_key) }

  let(:'X-Api-Key') { api_key.plain_key }

  let(:entity_ndjson) do
    {
      type: 'Account',
      data: {
        id: 'docs-account-1',
        name: 'Docs Checking',
        balance: '100.00',
        currency: 'USD',
        accountable_type: 'Depository'
      }
    }.to_json
  end

  let(:transaction_ndjson) do
    {
      type: 'Transaction',
      data: {
        id: 'docs-transaction-1',
        account_id: 'docs-account-1',
        date: '2024-01-15',
        amount: '-12.34',
        currency: 'USD',
        name: 'Docs Transaction'
      }
    }.to_json
  end

  path '/api/v1/import_sessions' do
    post 'Create import session' do
      description 'Create or idempotently retrieve a multi-file SureImport session keyed by client_session_id.'
      tags 'Import Sessions'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json'
      produces 'application/json'

      parameter name: :body, in: :body, required: false, schema: {
        type: :object,
        properties: {
          type: {
            type: :string,
            enum: %w[SureImport],
            description: 'Import session type. Only SureImport is supported.'
          },
          client_session_id: {
            type: :string,
            nullable: true,
            description: 'Client-provided idempotency key for the full import session.'
          },
          expected_chunks: {
            type: :integer,
            minimum: 1,
            nullable: true,
            description: 'Expected number of ordered chunks before publish is allowed.'
          }
        }
      }

      response '201', 'import session created' do
        schema '$ref' => '#/components/schemas/ImportSessionResponse'

        let(:body) do
          {
            type: 'SureImport',
            client_session_id: 'docs-session-1',
            expected_chunks: 2
          }
        end

        run_test!
      end

      response '401', 'unauthorized' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { nil }
        let(:body) { { type: 'SureImport' } }

        run_test!
      end

      response '403', 'insufficient scope' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { api_key_without_write_scope.plain_key }
        let(:body) { { type: 'SureImport' } }

        run_test!
      end

      response '409', 'client session conflict' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        before do
          family.import_sessions.create!(
            client_session_id: 'docs-session-conflict',
            expected_chunks: 1
          )
        end

        let(:body) do
          {
            type: 'SureImport',
            client_session_id: 'docs-session-conflict',
            expected_chunks: 2
          }
        end

        run_test!
      end

      response '422', 'validation error' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:body) { { type: 'TransactionImport' } }

        run_test!
      end
    end
  end

  path '/api/v1/import_sessions/{id}' do
    parameter name: :id, in: :path, type: :string, required: true, description: 'Import session ID'

    let(:import_session) { family.import_sessions.create!(expected_chunks: 1) }

    get 'Retrieve import session' do
      description 'Retrieve import session status, chunk status, per-entity summary counts, and safe error details.'
      tags 'Import Sessions'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      let(:id) { import_session.id }

      response '200', 'import session retrieved' do
        schema '$ref' => '#/components/schemas/ImportSessionResponse'

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

      response '404', 'import session not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { SecureRandom.uuid }

        run_test!
      end
    end
  end

  path '/api/v1/import_sessions/{id}/chunks' do
    parameter name: :id, in: :path, type: :string, required: true, description: 'Import session ID'

    let(:import_session) { family.import_sessions.create!(expected_chunks: 2) }
    let(:id) { import_session.id }

    post 'Upload import session chunk' do
      description 'Attach an ordered Sure NDJSON chunk to an import session. Chunks are idempotent by sequence and client_chunk_id with content verification.'
      tags 'Import Sessions'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json', 'multipart/form-data'
      produces 'application/json'
      metadata[:operation][:requestBody] = {
        required: true,
        content: {
          'application/json' => {
            schema: {
              type: :object,
              required: %w[sequence raw_file_content],
              properties: {
                sequence: {
                  type: :integer,
                  minimum: 1,
                  description: 'One-based chunk sequence. Earlier dependency chunks must have lower sequence numbers.'
                },
                client_chunk_id: {
                  type: :string,
                  nullable: true,
                  description: 'Client-provided idempotency key for this chunk.'
                },
                raw_file_content: {
                  type: :string,
                  description: 'Raw Sure NDJSON content. Each chunk is limited to 10MB.'
                }
              }
            }
          },
          'multipart/form-data' => {
            schema: {
              type: :object,
              required: %w[sequence file],
              properties: {
                sequence: {
                  type: :integer,
                  minimum: 1,
                  description: 'One-based chunk sequence. Earlier dependency chunks must have lower sequence numbers.'
                },
                client_chunk_id: {
                  type: :string,
                  nullable: true,
                  description: 'Client-provided idempotency key for this chunk.'
                },
                file: {
                  type: :string,
                  format: :binary,
                  description: 'Multipart Sure NDJSON file upload. Each chunk is limited to 10MB.'
                }
              }
            }
          }
        }
      }

      parameter name: :body, in: :body, required: false

      response '201', 'chunk uploaded' do
        schema '$ref' => '#/components/schemas/ImportSessionResponse'

        let(:body) do
          {
            sequence: 1,
            client_chunk_id: 'docs-entities',
            raw_file_content: entity_ndjson
          }
        end

        run_test!
      end

      response '401', 'unauthorized' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { nil }
        let(:body) { { sequence: 1, raw_file_content: entity_ndjson } }

        run_test!
      end

      response '403', 'insufficient scope' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { api_key_without_write_scope.plain_key }
        let(:body) { { sequence: 1, raw_file_content: entity_ndjson } }

        run_test!
      end

      response '409', 'chunk conflict' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        before do
          import_session.attach_chunk!(
            sequence: 1,
            client_chunk_id: 'docs-entities',
            content: entity_ndjson,
            filename: 'entities.ndjson',
            content_type: 'application/x-ndjson'
          )
        end

        let(:body) do
          {
            sequence: 1,
            client_chunk_id: 'docs-entities',
            raw_file_content: transaction_ndjson
          }
        end

        run_test!
      end

      response '404', 'import session not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { SecureRandom.uuid }
        let(:body) { { sequence: 1, raw_file_content: entity_ndjson } }

        run_test!
      end

      response '422', 'missing or invalid content' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:body) { { sequence: 1 } }

        run_test!
      end
    end
  end

  path '/api/v1/import_sessions/{id}/publish' do
    parameter name: :id, in: :path, type: :string, required: true, description: 'Import session ID'

    let(:import_session) { family.import_sessions.create!(expected_chunks: 1) }
    let(:id) { import_session.id }

    post 'Publish import session' do
      description 'Queue ordered chunk processing for a SureImport session. Later chunks can reference source IDs mapped by earlier chunks.'
      tags 'Import Sessions'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      response '202', 'import session publish queued' do
        schema '$ref' => '#/components/schemas/ImportSessionResponse'

        before do
          import_session.attach_chunk!(
            sequence: 1,
            client_chunk_id: 'docs-entities',
            content: entity_ndjson,
            filename: 'entities.ndjson',
            content_type: 'application/x-ndjson'
          )
        end

        run_test!
      end

      response '401', 'unauthorized' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { nil }

        run_test!
      end

      response '403', 'insufficient scope' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { api_key_without_write_scope.plain_key }

        run_test!
      end

      response '422', 'max_row_count_exceeded' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        before do
          import_session.attach_chunk!(
            sequence: 1,
            client_chunk_id: 'docs-entities',
            content: entity_ndjson,
            filename: 'entities.ndjson',
            content_type: 'application/x-ndjson'
          )
          import_session.imports.update_all(rows_count: SureImport.max_row_count + 1)
        end

        run_test!
      end

      response '409', 'missing expected chunks' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:import_session) { family.import_sessions.create!(expected_chunks: 2) }

        before do
          import_session.attach_chunk!(
            sequence: 1,
            client_chunk_id: 'docs-entities',
            content: entity_ndjson,
            filename: 'entities.ndjson',
            content_type: 'application/x-ndjson'
          )
        end

        run_test!
      end

      response '503', 'enqueue failed' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        before do
          import_session.attach_chunk!(
            sequence: 1,
            client_chunk_id: 'docs-entities',
            content: entity_ndjson,
            filename: 'entities.ndjson',
            content_type: 'application/x-ndjson'
          )
        end

        around do |example|
          ImportSessionJob.stub(:perform_later, ->(_import_session) { raise StandardError, 'queue offline' }) do
            example.run
          end
        end

        run_test!
      end

      response '404', 'import session not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { SecureRandom.uuid }

        run_test!
      end
    end
  end
end
