# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'API V1 Tags', type: :request do
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

  let!(:essential_tag) do
    family.tags.create!(name: 'Essential', color: '#22c55e')
  end

  let!(:discretionary_tag) do
    family.tags.create!(name: 'Discretionary', color: '#f97316')
  end

  let!(:recurring_tag) do
    family.tags.create!(name: 'Recurring', color: '#3b82f6')
  end

  path '/api/v1/tags' do
    get 'List tags' do
      tags 'Tags'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      response '200', 'tags listed' do
        schema '$ref' => '#/components/schemas/TagCollection'

        run_test!
      end
    end

    post 'Create tag' do
      tags 'Tags'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json'
      produces 'application/json'
      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        properties: {
          tag: {
            type: :object,
            properties: {
              name: { type: :string, description: 'Tag name (required)' },
              color: { type: :string, description: 'Hex color code (optional, auto-assigned if not provided)' }
            },
            required: %w[name]
          }
        },
        required: %w[tag]
      }

      response '201', 'tag created' do
        schema '$ref' => '#/components/schemas/TagDetail'

        let(:body) do
          {
            tag: {
              name: 'Business',
              color: '#8b5cf6'
            }
          }
        end

        run_test!
      end

      response '201', 'tag created with auto-assigned color' do
        schema '$ref' => '#/components/schemas/TagDetail'

        let(:body) do
          {
            tag: {
              name: 'Travel'
            }
          }
        end

        run_test!
      end

      response '422', 'validation error - missing name' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:body) do
          {
            tag: {
              color: '#8b5cf6'
            }
          }
        end

        run_test!
      end
    end
  end

  path '/api/v1/tags/{id}' do
    parameter name: :id, in: :path, type: :string, required: true, description: 'Tag ID'

    get 'Retrieve a tag' do
      tags 'Tags'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      let(:id) { essential_tag.id }

      response '200', 'tag retrieved' do
        schema '$ref' => '#/components/schemas/TagDetail'

        run_test!
      end

      response '404', 'tag not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { SecureRandom.uuid }

        run_test!
      end
    end

    patch 'Update a tag' do
      tags 'Tags'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json'
      produces 'application/json'

      let(:id) { essential_tag.id }

      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        properties: {
          tag: {
            type: :object,
            properties: {
              name: { type: :string },
              color: { type: :string }
            }
          }
        }
      }

      let(:body) do
        {
          tag: {
            name: 'Must Have',
            color: '#10b981'
          }
        }
      end

      response '200', 'tag updated' do
        schema '$ref' => '#/components/schemas/TagDetail'

        run_test!
      end

      response '404', 'tag not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { SecureRandom.uuid }

        run_test!
      end
    end

    delete 'Delete a tag' do
      tags 'Tags'
      security [ { apiKeyAuth: [] } ]

      let(:id) { recurring_tag.id }

      response '204', 'tag deleted' do
        run_test!
      end

      response '404', 'tag not found' do
        let(:id) { SecureRandom.uuid }

        run_test!
      end
    end
  end
end
