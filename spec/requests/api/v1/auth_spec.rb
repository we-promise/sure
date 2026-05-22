# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'API V1 Auth', type: :request do
  path '/api/v1/auth/signup' do
    post 'Sign up a new user' do
      tags 'Auth'
      consumes 'application/json'
      produces 'application/json'
      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        properties: {
          user: {
            type: :object,
            properties: {
              email: { type: :string, format: :email, description: 'User email address' },
              password: { type: :string, description: 'Password (min 8 chars, mixed case, number, special char)' },
              first_name: { type: :string },
              last_name: { type: :string }
            },
            required: %w[email password]
          },
          device: {
            type: :object,
            properties: {
              device_id: { type: :string, description: 'Unique device identifier' },
              device_name: { type: :string, description: 'Human-readable device name' },
              device_type: { type: :string, description: 'Device type (e.g. ios, android)' },
              os_version: { type: :string },
              app_version: { type: :string }
            },
            required: %w[device_id device_name device_type os_version app_version]
          },
          invite_code: { type: :string, nullable: true, description: 'Invite code (required when invites are enforced)' }
        },
        required: %w[user device]
      }

      response '201', 'user created' do
        schema type: :object,
               properties: {
                 access_token: { type: :string },
                 refresh_token: { type: :string },
                 token_type: { type: :string },
                 expires_in: { type: :integer },
                 created_at: { type: :integer },
                 user: {
                   type: :object,
                   properties: {
                     id: { type: :string, format: :uuid },
                     email: { type: :string },
                     first_name: { type: :string },
                     last_name: { type: :string },
                     ui_layout: { type: :string, enum: %w[dashboard intro] },
                     ai_enabled: { type: :boolean }
                   }
                 }
               }
        run_test!
      end

      response '422', 'validation error' do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        run_test!
      end

      response '403', 'invite code required or invalid' do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        run_test!
      end
    end
  end

  path '/api/v1/auth/login' do
    post 'Log in with email and password' do
      tags 'Auth'
      consumes 'application/json'
      produces 'application/json'
      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        properties: {
          email: { type: :string, format: :email },
          password: { type: :string },
          otp_code: { type: :string, nullable: true, description: 'TOTP code if MFA is enabled' },
          device: {
            type: :object,
            properties: {
              device_id: { type: :string },
              device_name: { type: :string },
              device_type: { type: :string },
              os_version: { type: :string },
              app_version: { type: :string }
            },
            required: %w[device_id device_name device_type os_version app_version]
          }
        },
        required: %w[email password device]
      }

      response '200', 'login successful' do
        schema type: :object,
               properties: {
                 access_token: { type: :string },
                 refresh_token: { type: :string },
                 token_type: { type: :string },
                 expires_in: { type: :integer },
                 created_at: { type: :integer },
                 user: {
                   type: :object,
                   properties: {
                     id: { type: :string, format: :uuid },
                     email: { type: :string },
                     first_name: { type: :string },
                     last_name: { type: :string },
                     ui_layout: { type: :string, enum: %w[dashboard intro] },
                     ai_enabled: { type: :boolean }
                   }
                 }
               }
        run_test!
      end

      response '401', 'invalid credentials or MFA required' do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        run_test!
      end
    end
  end

  path '/api/v1/auth/sso_exchange' do
    post 'Exchange mobile SSO authorization code for tokens' do
      tags 'Auth'
      consumes 'application/json'
      produces 'application/json'
      description 'Exchanges a one-time authorization code (received via deep link after mobile SSO) for OAuth tokens. The code is single-use and expires after 5 minutes.'
      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        properties: {
          code: { type: :string, description: 'One-time authorization code from mobile SSO callback' }
        },
        required: %w[code]
      }

      response '200', 'tokens issued' do
        schema type: :object,
               properties: {
                 access_token: { type: :string },
                 refresh_token: { type: :string },
                 token_type: { type: :string },
                 expires_in: { type: :integer },
                 created_at: { type: :integer },
                 user: {
                   type: :object,
                   properties: {
                     id: { type: :string, format: :uuid },
                     email: { type: :string },
                     first_name: { type: :string },
                     last_name: { type: :string },
                     ui_layout: { type: :string, enum: %w[dashboard intro] },
                     ai_enabled: { type: :boolean }
                   }
                 }
               }
        run_test!
      end

      response '401', 'invalid or expired code' do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        run_test!
      end
    end
  end

  path '/api/v1/auth/refresh' do
    post 'Refresh an access token' do
      tags 'Auth'
      consumes 'application/json'
      produces 'application/json'
      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        properties: {
          refresh_token: { type: :string, description: 'The refresh token from a previous login or refresh' },
          device: {
            type: :object,
            properties: {
              device_id: { type: :string }
            },
            required: %w[device_id]
          }
        },
        required: %w[refresh_token device]
      }

      response '200', 'token refreshed' do
        schema type: :object,
               properties: {
                 access_token: { type: :string },
                 refresh_token: { type: :string },
                 token_type: { type: :string },
                 expires_in: { type: :integer },
                 created_at: { type: :integer }
               }
        run_test!
      end

      response '401', 'invalid refresh token' do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        run_test!
      end

      response '400', 'missing refresh token' do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        run_test!
      end
    end
  end

  path '/api/v1/auth/sso_link' do
    post 'Link an existing account via SSO' do
      tags 'Auth'
      consumes 'application/json'
      produces 'application/json'
      description 'Authenticates with email/password and links the SSO identity from a previously issued linking code. Creates an OidcIdentity, logs the link via SsoAuditLog, and issues mobile OAuth tokens.'
      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        properties: {
          linking_code: { type: :string, description: 'One-time linking code from mobile SSO onboarding redirect' },
          email: { type: :string, format: :email, description: 'Email of the existing account to link' },
          password: { type: :string, description: 'Password for the existing account' }
        },
        required: %w[linking_code email password]
      }

      response '200', 'account linked and tokens issued' do
        schema type: :object,
               properties: {
                 access_token: { type: :string },
                 refresh_token: { type: :string },
                 token_type: { type: :string },
                 expires_in: { type: :integer },
                 created_at: { type: :integer },
                 user: {
                   type: :object,
                   properties: {
                     id: { type: :string, format: :uuid },
                     email: { type: :string },
                     first_name: { type: :string },
                     last_name: { type: :string },
                     ui_layout: { type: :string, enum: %w[dashboard intro] },
                     ai_enabled: { type: :boolean }
                   }
                 }
               }
        run_test!
      end

      response '400', 'missing linking code' do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        run_test!
      end

      response '401', 'invalid credentials or expired linking code' do
        schema oneOf: [
          { '$ref' => '#/components/schemas/ErrorResponse' },
          { '$ref' => '#/components/schemas/MfaRequiredResponse' }
        ]
        run_test!
      end
    end
  end

  path '/api/v1/auth/sso_create_account' do
    post 'Create a new account via SSO' do
      tags 'Auth'
      consumes 'application/json'
      produces 'application/json'
      description 'Creates a new user and family from a previously issued linking code. Links the SSO identity via OidcIdentity, logs the JIT account creation via SsoAuditLog, and issues mobile OAuth tokens. The linking code must have allow_account_creation enabled.'
      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        properties: {
          linking_code: { type: :string, description: 'One-time linking code from mobile SSO onboarding redirect' },
          first_name: { type: :string, description: 'First name (overrides value from SSO provider if provided)' },
          last_name: { type: :string, description: 'Last name (overrides value from SSO provider if provided)' }
        },
        required: %w[linking_code]
      }

      response '200', 'account created and tokens issued' do
        schema type: :object,
               properties: {
                 access_token: { type: :string },
                 refresh_token: { type: :string },
                 token_type: { type: :string },
                 expires_in: { type: :integer },
                 created_at: { type: :integer },
                 user: {
                   type: :object,
                   properties: {
                     id: { type: :string, format: :uuid },
                     email: { type: :string },
                     first_name: { type: :string },
                     last_name: { type: :string },
                     ui_layout: { type: :string, enum: %w[dashboard intro] },
                     ai_enabled: { type: :boolean }
                   }
                 }
               }
        run_test!
      end

      response '400', 'missing linking code' do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        run_test!
      end

      response '401', 'invalid or expired linking code' do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        run_test!
      end

      response '403', 'account creation disabled' do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        run_test!
      end

      response '422', 'user validation error' do
        schema type: :object,
               properties: {
                 errors: {
                   type: :array,
                   items: { type: :string }
                 }
               }
        run_test!
      end
    end
  end

  path '/api/v1/auth/enable_ai' do
    patch 'Enable AI features for the authenticated user' do
      tags 'Auth'
      consumes 'application/json'
      produces 'application/json'
      security [ { apiKeyAuth: [] } ]

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

      response '403', 'insufficient scope' do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        run_test!
      end
    end
  end
end
