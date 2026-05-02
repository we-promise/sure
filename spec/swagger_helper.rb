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
          ErrorResponseWithImportId: {
            type: :object,
            required: %w[error import_id],
            properties: {
              error: { type: :string },
              message: { type: :string, nullable: true },
              import_id: {
                type: :string,
                format: :uuid,
                description: 'Import ID preserved for retry or inspection after upload succeeds but publish fails'
              }
            }
          },
          MfaRequiredResponse: {
            type: :object,
            required: %w[error mfa_required],
            properties: {
              error: { type: :string },
              mfa_required: { type: :boolean }
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
              account_type: { type: :string, nullable: true },
              status: { type: :string }
            }
          },
          AccountDetail: {
            type: :object,
            required: %w[id name balance balance_cents cash_balance cash_balance_cents currency classification account_type status created_at updated_at],
            properties: {
              id: { type: :string, format: :uuid },
              name: { type: :string },
              balance: { type: :string },
              balance_cents: { type: :integer, description: 'Signed balance in minor currency units' },
              cash_balance: { type: :string },
              cash_balance_cents: { type: :integer, description: 'Signed cash balance in minor currency units' },
              currency: { type: :string },
              classification: { type: :string },
              account_type: { type: :string, nullable: true },
              subtype: { type: :string, nullable: true },
              status: { type: :string, enum: %w[active draft disabled pending_deletion] },
              institution_name: { type: :string, nullable: true },
              institution_domain: { type: :string, nullable: true },
              created_at: { type: :string, format: :'date-time' },
              updated_at: { type: :string, format: :'date-time' }
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
            required: %w[id name color icon],
            properties: {
              id: { type: :string, format: :uuid },
              name: { type: :string },
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
            required: %w[id name color icon subcategories_count created_at updated_at],
            properties: {
              id: { type: :string, format: :uuid },
              name: { type: :string },
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
          RuleAction: {
            type: :object,
            required: %w[id action_type created_at updated_at],
            properties: {
              id: { type: :string, format: :uuid },
              action_type: { type: :string },
              value: { type: :string, nullable: true },
              created_at: { type: :string, format: :'date-time' },
              updated_at: { type: :string, format: :'date-time' }
            }
          },
          RuleCondition: {
            type: :object,
            required: %w[id condition_type operator sub_conditions created_at updated_at],
            properties: {
              id: { type: :string, format: :uuid },
              condition_type: { type: :string },
              operator: { type: :string },
              value: { type: :string, nullable: true },
              sub_conditions: {
                type: :array,
                items: { '$ref' => '#/components/schemas/RuleCondition' }
              },
              created_at: { type: :string, format: :'date-time' },
              updated_at: { type: :string, format: :'date-time' }
            }
          },
          Rule: {
            type: :object,
            required: %w[id resource_type active conditions actions created_at updated_at],
            properties: {
              id: { type: :string, format: :uuid },
              name: { type: :string, nullable: true },
              resource_type: { type: :string, enum: %w[transaction] },
              active: { type: :boolean },
              effective_date: { type: :string, format: :date, nullable: true },
              conditions: {
                type: :array,
                items: { '$ref' => '#/components/schemas/RuleCondition' }
              },
              actions: {
                type: :array,
                items: { '$ref' => '#/components/schemas/RuleAction' }
              },
              created_at: { type: :string, format: :'date-time' },
              updated_at: { type: :string, format: :'date-time' }
            }
          },
          RuleResponse: {
            type: :object,
            required: %w[data],
            properties: {
              data: { '$ref' => '#/components/schemas/Rule' }
            }
          },
          RuleCollection: {
            type: :object,
            required: %w[data meta],
            properties: {
              data: {
                type: :array,
                items: { '$ref' => '#/components/schemas/Rule' }
              },
              meta: {
                type: :object,
                required: %w[current_page total_pages total_count per_page],
                properties: {
                  current_page: { type: :integer },
                  next_page: { type: :integer, nullable: true },
                  prev_page: { type: :integer, nullable: true },
                  total_pages: { type: :integer },
                  total_count: { type: :integer },
                  per_page: { type: :integer }
                }
              }
            }
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
          RecurringTransaction: {
            type: :object,
            required: %w[id amount amount_cents currency expected_day_of_month last_occurrence_date next_expected_date status occurrence_count manual created_at updated_at],
            properties: {
              id: { type: :string, format: :uuid },
              amount: { type: :string },
              amount_cents: { type: :integer, description: 'Amount in currency minor units' },
              currency: { type: :string },
              expected_day_of_month: { type: :integer, minimum: 1, maximum: 31 },
              last_occurrence_date: { type: :string, format: :date },
              next_expected_date: { type: :string, format: :date },
              status: { type: :string, enum: %w[active inactive] },
              occurrence_count: { type: :integer, minimum: 0 },
              name: { type: :string, nullable: true },
              manual: { type: :boolean },
              expected_amount_min: { type: :string, nullable: true },
              expected_amount_min_cents: { type: :integer, nullable: true, description: 'Minimum expected amount in currency minor units' },
              expected_amount_max: { type: :string, nullable: true },
              expected_amount_max_cents: { type: :integer, nullable: true, description: 'Maximum expected amount in currency minor units' },
              expected_amount_avg: { type: :string, nullable: true },
              expected_amount_avg_cents: { type: :integer, nullable: true, description: 'Average expected amount in currency minor units' },
              account: { '$ref' => '#/components/schemas/Account', nullable: true },
              merchant: { '$ref' => '#/components/schemas/Merchant', nullable: true },
              created_at: { type: :string, format: :'date-time' },
              updated_at: { type: :string, format: :'date-time' }
            }
          },
          RecurringTransactionCollection: {
            type: :object,
            required: %w[recurring_transactions pagination],
            properties: {
              recurring_transactions: {
                type: :array,
                items: { '$ref' => '#/components/schemas/RecurringTransaction' }
              },
              pagination: { '$ref' => '#/components/schemas/Pagination' }
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
          ValuationCollection: {
            type: :object,
            required: %w[valuations pagination],
            properties: {
              valuations: {
                type: :array,
                items: { '$ref' => '#/components/schemas/Valuation' }
              },
              pagination: { '$ref' => '#/components/schemas/Pagination' }
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
            required: %w[rows_count valid_rows_count invalid_rows_count mappings_count unassigned_mappings_count],
            properties: {
              rows_count: { type: :integer, minimum: 0 },
              valid_rows_count: { type: :integer, minimum: 0 },
              invalid_rows_count: { type: :integer, minimum: 0 },
              mappings_count: { type: :integer, minimum: 0 },
              unassigned_mappings_count: { type: :integer, minimum: 0 }
            }
          },
          ImportStatusSummary: {
            type: :object,
            required: %w[uploaded configured terminal],
            properties: {
              uploaded: { type: :boolean },
              configured: { type: :boolean },
              terminal: { type: :boolean }
            }
          },
          ImportStatusDetail: {
            allOf: [
              { '$ref' => '#/components/schemas/ImportStatusSummary' },
              {
                type: :object,
                required: %w[cleaned publishable revertable],
                properties: {
                  cleaned: { type: :boolean },
                  publishable: { type: :boolean },
                  revertable: { type: :boolean }
                }
              }
            ]
          },
          ImportSummary: {
            type: :object,
            required: %w[id type status created_at updated_at status_detail],
            properties: {
              id: { type: :string, format: :uuid },
              type: { type: :string, enum: %w[TransactionImport TradeImport AccountImport MintImport CategoryImport RuleImport SureImport] },
              status: { type: :string, enum: %w[pending complete importing reverting revert_failed failed] },
              created_at: { type: :string, format: :'date-time' },
              updated_at: { type: :string, format: :'date-time' },
              account_id: { type: :string, format: :uuid, nullable: true },
              rows_count: { type: :integer, minimum: 0 },
              error: { type: :string, nullable: true },
              status_detail: { '$ref' => '#/components/schemas/ImportStatusSummary' }
            }
          },
          ImportDetail: {
            type: :object,
            required: %w[id type status created_at updated_at status_detail configuration stats],
            properties: {
              id: { type: :string, format: :uuid },
              type: { type: :string, enum: %w[TransactionImport TradeImport AccountImport MintImport CategoryImport RuleImport SureImport] },
              status: { type: :string, enum: %w[pending complete importing reverting revert_failed failed] },
              created_at: { type: :string, format: :'date-time' },
              updated_at: { type: :string, format: :'date-time' },
              account_id: { type: :string, format: :uuid, nullable: true },
              error: { type: :string, nullable: true },
              status_detail: { '$ref' => '#/components/schemas/ImportStatusDetail' },
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
          },
          Money: {
            type: :object,
            required: %w[amount currency formatted],
            properties: {
              amount: { type: :string, description: 'Numeric amount as string' },
              currency: { type: :string, description: 'ISO 4217 currency code' },
              formatted: { type: :string, description: 'Locale-formatted money string' }
            }
          },
          BalanceSheet: {
            type: :object,
            required: %w[currency net_worth assets liabilities],
            properties: {
              currency: { type: :string, description: 'Family primary currency' },
              net_worth: { '$ref' => '#/components/schemas/Money' },
              assets: { '$ref' => '#/components/schemas/Money' },
              liabilities: { '$ref' => '#/components/schemas/Money' }
            }
          },
          SuccessMessage: {
            type: :object,
            required: %w[message],
            properties: {
              message: { type: :string }
            }
          }
        }
      }
    }
  }

  config.openapi_format = :yaml
end
