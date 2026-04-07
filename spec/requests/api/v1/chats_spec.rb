# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'API V1 Chats', type: :request do
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
      password_confirmation: 'password123',
      ai_enabled: true
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

  let!(:chat) do
    user.chats.create!(title: 'Budget planning').tap do |record|
      record.messages.create!(
        type: 'UserMessage',
        content: 'How should I budget for a vacation?',
        ai_model: 'gpt-4'
      )

      assistant_message = record.messages.create!(
        type: 'AssistantMessage',
        content: "Let's review your spending patterns first.",
        ai_model: 'gpt-4'
      )

      assistant_message.tool_calls.create!(
        provider_id: 'openai',
        type: 'ToolCall::Function',
        function_name: 'get_accounts',
        function_arguments: { 'scope' => 'spending' },
        function_result: { 'total_spend' => 1500 }
      )

      record.messages.create!(
        type: 'AssistantMessage',
        content: 'Does this align with your savings goals?',
        ai_model: 'gpt-4'
      )
    end
  end

  let!(:another_chat) do
    user.chats.create!(title: 'Retirement planning').tap do |record|
      record.messages.create!(
        type: 'UserMessage',
        content: 'How much should I contribute to my IRA?',
        ai_model: 'gpt-4'
      )
    end
  end

  path '/api/v1/chats' do
    get 'List chats' do
      tags 'Chats'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      response '200', 'chats listed' do
        schema '$ref' => '#/components/schemas/ChatCollection'

        run_test!
      end

      response '403', 'AI features disabled' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:user) do
          family.users.create!(
            email: 'no-ai@example.com',
            password: 'password123',
            password_confirmation: 'password123',
            ai_enabled: false
          )
        end

        run_test!
      end
    end

    post 'Create chat' do
      tags 'Chats'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json'
      produces 'application/json'
      parameter name: :chat_params, in: :body, required: true, schema: {
        type: :object,
        properties: {
          title: { type: :string, example: 'Monthly budget review' },
          message: { type: :string, description: 'Optional initial message in the chat' },
          model: { type: :string, description: 'Optional OpenAI model identifier' }
        },
        required: %w[title]
      }

      let(:chat_params) do
        {
          title: 'Travel planning',
          message: 'Can you help me plan a summer trip?',
          model: 'gpt-4-turbo'
        }
      end

      response '201', 'chat created' do
        schema '$ref' => '#/components/schemas/ChatDetail'

        run_test!
      end

      response '422', 'validation error' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:chat_params) { { title: '' } }

        run_test!
      end
    end
  end

  path '/api/v1/chats/{id}' do
    parameter name: :id, in: :path, type: :string, required: true, description: 'Chat ID'

    get 'Retrieve a chat' do
      tags 'Chats'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      let(:id) { chat.id }

      response '200', 'chat retrieved' do
        schema '$ref' => '#/components/schemas/ChatDetail'

        run_test!
      end

      response '404', 'chat not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { SecureRandom.uuid }

        run_test!
      end
    end

    patch 'Update a chat' do
      tags 'Chats'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json'
      produces 'application/json'

      let(:id) { chat.id }

      parameter name: :chat_params, in: :body, required: true, schema: {
        type: :object,
        properties: {
          title: { type: :string, example: 'Updated chat title' }
        }
      }

      let(:chat_params) { { title: 'Updated budget plan' } }

      response '200', 'chat updated' do
        schema '$ref' => '#/components/schemas/ChatDetail'

        run_test!
      end

      response '404', 'chat not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { SecureRandom.uuid }

        run_test!
      end

      response '422', 'validation error' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:chat_params) { { title: '' } }

        run_test!
      end
    end

    delete 'Delete a chat' do
      tags 'Chats'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      let(:id) { another_chat.id }

      response '204', 'chat deleted' do
        run_test!
      end

      response '404', 'chat not found' do
        let(:id) { SecureRandom.uuid }

        run_test!
      end
    end
  end

  path '/api/v1/chats/{chat_id}/messages' do
    parameter name: :chat_id, in: :path, type: :string, required: true, description: 'Chat ID'

    post 'Create a message' do
      tags 'Chat Messages'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json'
      produces 'application/json'

      let(:chat_id) { chat.id }

      parameter name: :message_params, in: :body, required: true, schema: {
        type: :object,
        properties: {
          content: { type: :string },
          model: { type: :string }
        },
        required: %w[content]
      }

      let(:message_params) do
        {
          content: 'Please summarise the last conversation.',
          model: 'gpt-4'
        }
      end

      response '201', 'message created' do
        schema '$ref' => '#/components/schemas/MessageResponse'

        run_test!
      end

      response '404', 'chat not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:chat_id) { SecureRandom.uuid }

        run_test!
      end

      response '422', 'validation error' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:message_params) { { content: '' } }

        run_test!
      end
    end
  end

  path '/api/v1/chats/{chat_id}/messages/retry' do
    parameter name: :chat_id, in: :path, type: :string, required: true, description: 'Chat ID'

    post 'Retry the last assistant response' do
      tags 'Chat Messages'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      let(:chat_id) { chat.id }

      response '202', 'retry started' do
        schema '$ref' => '#/components/schemas/RetryResponse'

        before do
          allow_any_instance_of(AssistantMessage).to receive(:valid?).and_return(true)
        end

        run_test!
      end

      response '404', 'chat not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:chat_id) { SecureRandom.uuid }

        run_test!
      end

      response '422', 'no assistant message available' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:chat) do
          user.chats.create!(title: 'Empty conversation')
        end

        let(:chat_id) { chat.id }

        run_test!
      end
    end
  end
end
