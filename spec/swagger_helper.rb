# frozen_string_literal: true

require 'rails_helper'

RSpec.configure do |config|
  config.openapi_root = Rails.root.join('docs', 'api').to_s

  config.openapi_specs = {
    'openapi.yaml' => {
      openapi: '3.0.3',
      info: {
        title: 'Sure API',
        version: 'v1',
        description: 'OpenAPI documentation generated from executable request specs.'
      },
      servers: [
        {
          url: 'https://app.sure.am',
          description: 'Production'
        },
        {
          url: 'http://localhost:3000',
          description: 'Local development'
        }
      ],
      components: {
        securitySchemes: {
          apiKeyAuth: {
            type: :apiKey,
            name: 'X-Api-Key',
            in: :header,
            description: 'API key for authentication. Generate one from your account settings.'
          }
        },
        schemas: {
          Pagination: {
            type: :object,
            required: %w[page per_page total_count total_pages],
            properties: {
              page: { type: :integer, minimum: 1 },
              per_page: { type: :integer, minimum: 1 },
              total_count: { type: :integer, minimum: 0 },
              total_pages: { type: :integer, minimum: 0 }
            }
          },
          ErrorResponse: {
            type: :object,
            required: %w[error],
            properties: {
              error: { type: :string },
              message: { type: :string, nullable: true },
              details: {
                oneOf: [
                  { type: :array, items: { type: :string } },
                  { type: :object }
                ],
                nullable: true
              },
              errors: {
                type: :array,
                items: { type: :string },
                nullable: true,
                description: 'Validation error messages (alternative to details used by trades, valuations, etc.)'
              }
            }
          },
          ToolCall: {
            type: :object,
            required: %w[id function_name function_arguments created_at],
            properties: {
              id: { type: :string, format: :uuid },
              function_name: { type: :string },
              function_arguments: { type: :object, additionalProperties: true },
              function_result: { type: :object, additionalProperties: true, nullable: true },
              created_at: { type: :string, format: :'date-time' }
            }
          },
          Message: {
            type: :object,
            required: %w[id type role content created_at updated_at],
            properties: {
              id: { type: :string, format: :uuid },
              type: { type: :string, enum: %w[user_message assistant_message] },
              role: { type: :string, enum: %w[user assistant] },
              content: { type: :string },
              model: { type: :string, nullable: true },
              created_at: { type: :string, format: :'date-time' },
              updated_at: { type: :string, format: :'date-time' },
              tool_calls: {
                type: :array,
                items: { '$ref' => '#/components/schemas/ToolCall' },
                nullable: true
              }
            }
          },
          MessageResponse: {
            allOf: [
              { '$ref' => '#/components/schemas/Message' },
              {
                type: :object,
                required: %w[chat_id],
                properties: {
                  chat_id: { type: :string, format: :uuid },
                  ai_response_status: { type: :string, enum: %w[pending complete failed], nullable: true },
                  ai_response_message: { type: :string, nullable: true }
                }
              }
            ]
          },
          ChatResource: {
            type: :object,
            required: %w[id title created_at updated_at],
            properties: {
              id: { type: :string, format: :uuid },
              title: { type: :string },
              error: { type: :string, nullable: true },
              created_at: { type: :string, format: :'date-time' },
              updated_at: { type: :string, format: :'date-time' }
            }
          },
          ChatSummary: {
            allOf: [
              { '$ref' => '#/components/schemas/ChatResource' },
              {
                type: :object,
                required: %w[message_count],
                properties: {
                  message_count: { type: :integer, minimum: 0 },
                  last_message_at: { type: :string, format: :'date-time', nullable: true }
                }
              }
            ]
          },
          ChatDetail: {
            allOf: [
              { '$ref' => '#/components/schemas/ChatResource' },
              {
                type: :object,
                required: %w[messages],
                properties: {
                  messages: {
                    type: :array,
                    items: { '$ref' => '#/components/schemas/Message' }
                  },
                  pagination: {
                    '$ref' => '#/components/schemas/Pagination',
                    nullable: true
                  }
                }
              }
            ]
          },
          ChatCollection: {
            type: :object,
            required: %w[chats pagination],
            properties: {
              chats: {
                type: :array,
                items: { '$ref' => '#/components/schemas/ChatSummary' }
              },
              pagination: { '$ref' => '#/components/schemas/Pagination' }
            }
          },
          RetryResponse: {
            type: :object,
            required: %w[message message_id],
            properties: {
              message: { type: :string },
              message_id: { type: :string, format: :uuid }
            }
          },
          Account: {
            type: :object,
            required: %w[id name account_type],
            properties: {
              id: { type: :string, format: :uuid },
              name: { type: :string },
              account_type: { type: :string }
            }
          },
          AccountDetail: {
            type: :object,
            required: %w[id name balance currency classification account_type],
            properties: {
              id: { type: :string, format: :uuid },
              name: { type: :string },
              balance: { type: :string },
              currency: { type: :string },
              classification: { type: :string },
              account_type: { type: :string }
            }
          },
          AccountCollection: {
            type: :object,
            required: %w[accounts pagination],
            properties: {
              accounts: {
                type: :array,
                items: { '$ref' => '#/components/schemas/AccountDetail' }
              },
              pagination: { '$ref' => '#/components/schemas/Pagination' }
            }
          },
          Category: {
            type: :object,
            required: %w[id name classification color icon],
            properties: {
              id: { type: :string, format: :uuid },
              name: { type: :string },
              classification: { type: :string },
              color: { type: :string },
              icon: { type: :string }
            }
          },
          CategoryParent: {
            type: :object,
            required: %w[id name],
            properties: {
              id: { type: :string, format: :uuid },
              name: { type: :string }
            }
          },
          CategoryDetail: {
            type: :object,
            required: %w[id name classification color icon subcategories_count created_at updated_at],
            properties: {
              id: { type: :string, format: :uuid },
              name: { type: :string },
              classification: { type: :string, enum: %w[income expense] },
              color: { type: :string },
              icon: { type: :string },
              parent: { '$ref' => '#/components/schemas/CategoryParent', nullable: true },
              subcategories_count: { type: :integer, minimum: 0 },
              created_at: { type: :string, format: :'date-time' },
              updated_at: { type: :string, format: :'date-time' }
            }
          },
          CategoryCollection: {
            type: :object,
            required: %w[categories pagination],
            properties: {
              categories: {
                type: :array,
                items: { '$ref' => '#/components/schemas/CategoryDetail' }
              },
              pagination: { '$ref' => '#/components/schemas/Pagination' }
            }
          },
          Merchant: {
            type: :object,
            required: %w[id name],
            properties: {
              id: { type: :string, format: :uuid },
              name: { type: :string }
            }
          },
          MerchantDetail: {
            type: :object,
            required: %w[id name type created_at updated_at],
            properties: {
              id: { type: :string, format: :uuid },
              name: { type: :string },
              type: { type: :string, enum: %w[FamilyMerchant ProviderMerchant] },
              created_at: { type: :string, format: :'date-time' },
              updated_at: { type: :string, format: :'date-time' }
            }
          },
          Tag: {
            type: :object,
            required: %w[id name color],
            properties: {
              id: { type: :string, format: :uuid },
              name: { type: :string },
              color: { type: :string }
            }
          },
          TagDetail: {
            type: :object,
            required: %w[id name color created_at updated_at],
            properties: {
              id: { type: :string, format: :uuid },
              name: { type: :string },
              color: { type: :string },
              created_at: { type: :string, format: :'date-time' },
              updated_at: { type: :string, format: :'date-time' }
            }
          },
          TagCollection: {
            type: :array,
            items: { '$ref' => '#/components/schemas/TagDetail' }
          },
          Transfer: {
            type: :object,
            required: %w[id amount currency],
            properties: {
              id: { type: :string, format: :uuid },
              amount: { type: :string },
              currency: { type: :string },
              other_account: { '$ref' => '#/components/schemas/Account', nullable: true }
            }
          },
          Transaction: {
            type: :object,
            required: %w[id date amount currency name classification account tags created_at updated_at],
            properties: {
              id: { type: :string, format: :uuid },
              date: { type: :string, format: :date },
              amount: { type: :string },
              currency: { type: :string },
              name: { type: :string },
              notes: { type: :string, nullable: true },
              classification: { type: :string },
              account: { '$ref' => '#/components/schemas/Account' },
              category: { '$ref' => '#/components/schemas/Category', nullable: true },
              merchant: { '$ref' => '#/components/schemas/Merchant', nullable: true },
              tags: {
                type: :array,
                items: { '$ref' => '#/components/schemas/Tag' }
              },
              transfer: { '$ref' => '#/components/schemas/Transfer', nullable: true },
              created_at: { type: :string, format: :'date-time' },
              updated_at: { type: :string, format: :'date-time' }
            }
          },
          TransactionCollection: {
            type: :object,
            required: %w[transactions pagination],
            properties: {
              transactions: {
                type: :array,
                items: { '$ref' => '#/components/schemas/Transaction' }
              },
              pagination: { '$ref' => '#/components/schemas/Pagination' }
            }
          },
          Valuation: {
            type: :object,
            required: %w[id date amount currency kind account created_at updated_at],
            properties: {
              id: { type: :string, format: :uuid },
              date: { type: :string, format: :date },
              amount: { type: :string },
              currency: { type: :string },
              notes: { type: :string, nullable: true },
              kind: { type: :string },
              account: { '$ref' => '#/components/schemas/Account' },
              created_at: { type: :string, format: :'date-time' },
              updated_at: { type: :string, format: :'date-time' }
            }
          },
          DeleteResponse: {
            type: :object,
            required: %w[message],
            properties: {
              message: { type: :string }
            }
          },
          ImportConfiguration: {
            type: :object,
            properties: {
              date_col_label: { type: :string, nullable: true },
              amount_col_label: { type: :string, nullable: true },
              name_col_label: { type: :string, nullable: true },
              category_col_label: { type: :string, nullable: true },
              tags_col_label: { type: :string, nullable: true },
              notes_col_label: { type: :string, nullable: true },
              account_col_label: { type: :string, nullable: true },
              date_format: { type: :string, nullable: true },
              number_format: { type: :string, nullable: true },
              signage_convention: { type: :string, nullable: true }
            }
          },
          ImportStats: {
            type: :object,
            properties: {
              rows_count: { type: :integer, minimum: 0 },
              valid_rows_count: { type: :integer, minimum: 0, nullable: true }
            }
          },
          ImportSummary: {
            type: :object,
            required: %w[id type status created_at updated_at],
            properties: {
              id: { type: :string, format: :uuid },
              type: { type: :string, enum: %w[TransactionImport TradeImport AccountImport MintImport CategoryImport RuleImport] },
              status: { type: :string, enum: %w[pending complete importing reverting revert_failed failed] },
              created_at: { type: :string, format: :'date-time' },
              updated_at: { type: :string, format: :'date-time' },
              account_id: { type: :string, format: :uuid, nullable: true },
              rows_count: { type: :integer, minimum: 0 },
              error: { type: :string, nullable: true }
            }
          },
          ImportDetail: {
            type: :object,
            required: %w[id type status created_at updated_at],
            properties: {
              id: { type: :string, format: :uuid },
              type: { type: :string, enum: %w[TransactionImport TradeImport AccountImport MintImport CategoryImport RuleImport] },
              status: { type: :string, enum: %w[pending complete importing reverting revert_failed failed] },
              created_at: { type: :string, format: :'date-time' },
              updated_at: { type: :string, format: :'date-time' },
              account_id: { type: :string, format: :uuid, nullable: true },
              error: { type: :string, nullable: true },
              configuration: { '$ref' => '#/components/schemas/ImportConfiguration' },
              stats: { '$ref' => '#/components/schemas/ImportStats' }
            }
          },
          ImportCollection: {
            type: :object,
            required: %w[data meta],
            properties: {
              data: {
                type: :array,
                items: { '$ref' => '#/components/schemas/ImportSummary' }
              },
              meta: {
                type: :object,
                required: %w[current_page total_pages total_count per_page],
                properties: {
                  current_page: { type: :integer, minimum: 1 },
                  next_page: { type: :integer, nullable: true },
                  prev_page: { type: :integer, nullable: true },
                  total_pages: { type: :integer, minimum: 0 },
                  total_count: { type: :integer, minimum: 0 },
                  per_page: { type: :integer, minimum: 1 }
                }
              }
            }
          },
          ImportResponse: {
            type: :object,
            required: %w[data],
            properties: {
              data: { '$ref' => '#/components/schemas/ImportDetail' }
            }
          },
          Trade: {
            type: :object,
            required: %w[id date amount currency name qty price account created_at updated_at],
            properties: {
              id: { type: :string, format: :uuid },
              date: { type: :string, format: :date },
              amount: { type: :string },
              currency: { type: :string },
              name: { type: :string },
              notes: { type: :string, nullable: true },
              qty: { type: :string },
              price: { type: :string },
              investment_activity_label: { type: :string, nullable: true },
              account: { '$ref' => '#/components/schemas/Account' },
              security: {
                type: :object,
                nullable: true,
                properties: {
                  id: { type: :string, format: :uuid },
                  ticker: { type: :string },
                  name: { type: :string, nullable: true }
                }
              },
              category: {
                type: :object,
                nullable: true,
                properties: {
                  id: { type: :string, format: :uuid },
                  name: { type: :string }
                }
              },
              created_at: { type: :string, format: :'date-time' },
              updated_at: { type: :string, format: :'date-time' }
            }
          },
          TradeCollection: {
            type: :object,
            required: %w[trades pagination],
            properties: {
              trades: {
                type: :array,
                items: { '$ref' => '#/components/schemas/Trade' }
              },
              pagination: { '$ref' => '#/components/schemas/Pagination' }
            }
          },
          Holding: {
            type: :object,
            required: %w[id date qty price amount currency account security created_at updated_at],
            properties: {
              id: { type: :string, format: :uuid },
              date: { type: :string, format: :date },
              qty: { type: :string, description: 'Quantity of shares held' },
              price: { type: :string, description: 'Formatted price per share' },
              amount: { type: :string },
              currency: { type: :string },
              cost_basis_source: { type: :string, nullable: true },
              account: { '$ref' => '#/components/schemas/Account' },
              security: {
                type: :object,
                required: %w[id ticker name],
                properties: {
                  id: { type: :string, format: :uuid },
                  ticker: { type: :string },
                  name: { type: :string, nullable: true }
                }
              },
              avg_cost: { type: :string, nullable: true },
              created_at: { type: :string, format: :'date-time' },
              updated_at: { type: :string, format: :'date-time' }
            }
          },
          HoldingCollection: {
            type: :object,
            required: %w[holdings pagination],
            properties: {
              holdings: {
                type: :array,
                items: { '$ref' => '#/components/schemas/Holding' }
              },
              pagination: { '$ref' => '#/components/schemas/Pagination' }
            }
          }
        }
      }
    }
  }

  config.openapi_format = :yaml
end
