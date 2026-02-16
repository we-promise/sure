# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'API V1 Users', type: :request do
  path '/api/v1/user/enable_ai' do
    patch 'Enable AI features for the authenticated user' do
      tags 'Users'
      consumes 'application/json'
      produces 'application/json'
      security [{ apiKeyAuth: [] }]

      response '200', 'ai enabled' do
        schema type: :object,
               properties: {
                 user: {
                   type: :object,
                   properties: {
                     id: { type: :string, format: :uuid },
                     email: { type: :string },
                     first_name: { type: :string, nullable: true },
                     last_name: { type: :string, nullable: true },
                     ui_layout: { type: :string, enum: %w[dashboard intro] },
                     ai_enabled: { type: :boolean }
                   }
                 }
               }
        run_test!
      end

      response '401', 'unauthorized' do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        run_test!
      end
    end
  end
end
