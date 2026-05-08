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
          FamilyExportFile: {
            type: :object,
            required: %w[attached],
            properties: {
              attached: { type: :boolean },
              byte_size: { type: :integer, nullable: true, minimum: 0 },
              content_type: { type: :string, nullable: true }
            }
          },
          FamilyExport: {
            type: :object,
            required: %w[id status filename downloadable file created_at updated_at],
            properties: {
              id: { type: :string, format: :uuid },
              status: { type: :string, enum: %w[pending processing completed failed] },
              filename: { type: :string },
              downloadable: { type: :boolean },
              download_path: { type: :string, nullable: true },
              file: { '$ref' => '#/components/schemas/FamilyExportFile' },
              created_at: { type: :string, format: :'date-time' },
              updated_at: { type: :string, format: :'date-time' }
            }
          },
          FamilyExportResponse: {
            type: :object,
            required: %w[data],
            properties: {
              data: { '$ref' => '#/components/schemas/FamilyExport' }
            }
          },
          FamilyExportCollection: {
            type: :object,
            required: %w[data meta],
            properties: {
              data: {
                type: :array,
                maxItems: 100,
                items: { '$ref' => '#/components/schemas/FamilyExport' }
              },
              meta: { '$ref' => '#/components/schemas/Pagination' }
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
          FamilySettings: {
            type: :object,
            required: %w[id currency locale date_format month_start_day moniker default_account_sharing custom_enabled_currencies enabled_currencies created_at updated_at],
            properties: {
              id: { type: :string, format: :uuid },
              name: { type: :string, nullable: true },
              currency: { type: :string },
              locale: { type: :string },
              date_format: { type: :string },
              country: { type: :string, nullable: true },
              timezone: { type: :string, nullable: true },
              month_start_day: { type: :integer, minimum: 1, maximum: 28 },
              moniker: { type: :string, enum: Family::MONIKERS },
              default_account_sharing: { type: :string, enum: %w[shared private] },
              custom_enabled_currencies: { type: :boolean },
              enabled_currencies: {
                type: :array,
                items: { type: :string }
              },
              created_at: { type: :string, format: :'date-time' },
              updated_at: { type: :string, format: :'date-time' }
            }
          },
          BudgetSummary: {
            type: :object,
            required: %w[id start_date end_date name currency initialized current created_at updated_at],
            properties: {
              id: { type: :string, format: :uuid },
              start_date: { type: :string, format: :date },
              end_date: { type: :string, format: :date },
              name: { type: :string },
              currency: { type: :string },
              initialized: { type: :boolean },
              current: { type: :boolean },
              budgeted_spending: { type: :string, nullable: true },
              budgeted_spending_cents: { type: :integer, nullable: true },
              expected_income: { type: :string, nullable: true },
              expected_income_cents: { type: :integer, nullable: true },
              allocated_spending: { type: :string },
              allocated_spending_cents: { type: :integer },
              created_at: { type: :string, format: :'date-time' },
              updated_at: { type: :string, format: :'date-time' }
            }
          },
          Budget: {
            type: :object,
            required: %w[id start_date end_date name currency initialized current created_at updated_at],
            properties: {
              id: { type: :string, format: :uuid },
              start_date: { type: :string, format: :date },
              end_date: { type: :string, format: :date },
              name: { type: :string },
              currency: { type: :string },
              initialized: { type: :boolean },
              current: { type: :boolean },
              budgeted_spending: { type: :string, nullable: true },
              budgeted_spending_cents: { type: :integer, nullable: true },
              expected_income: { type: :string, nullable: true },
              expected_income_cents: { type: :integer, nullable: true },
              allocated_spending: { type: :string },
              allocated_spending_cents: { type: :integer },
              actual_spending: { type: :string },
              actual_spending_cents: { type: :integer },
              actual_income: { type: :string },
              actual_income_cents: { type: :integer },
              available_to_spend: { type: :string },
              available_to_spend_cents: { type: :integer },
              available_to_allocate: { type: :string },
              available_to_allocate_cents: { type: :integer },
              created_at: { type: :string, format: :'date-time' },
              updated_at: { type: :string, format: :'date-time' }
            }
          },
          BudgetCollection: {
            type: :object,
            required: %w[budgets pagination],
            properties: {
              budgets: {
                type: :array,
                items: { '$ref' => '#/components/schemas/BudgetSummary' }
              },
              pagination: { '$ref' => '#/components/schemas/Pagination' }
            }
          },
          BudgetCategorySummary: {
            type: :object,
            required: %w[id budget_id currency subcategory inherits_parent_budget category created_at updated_at],
            properties: {
              id: { type: :string, format: :uuid },
              budget_id: { type: :string, format: :uuid },
              currency: { type: :string },
              subcategory: { type: :boolean },
              inherits_parent_budget: { type: :boolean },
              budgeted_spending: { type: :string },
              budgeted_spending_cents: { type: :integer },
              display_budgeted_spending: { type: :string },
              display_budgeted_spending_cents: { type: :integer },
              category: {
                type: :object,
                required: %w[id name color lucide_icon],
                properties: {
                  id: { type: :string, format: :uuid },
                  name: { type: :string },
                  color: { type: :string },
                  lucide_icon: { type: :string },
                  parent_id: { type: :string, format: :uuid, nullable: true }
                }
              },
              created_at: { type: :string, format: :'date-time' },
              updated_at: { type: :string, format: :'date-time' }
            }
          },
          BudgetCategory: {
            type: :object,
            required: %w[id budget_id currency subcategory inherits_parent_budget category created_at updated_at],
            properties: {
              id: { type: :string, format: :uuid },
              budget_id: { type: :string, format: :uuid },
              currency: { type: :string },
              subcategory: { type: :boolean },
              inherits_parent_budget: { type: :boolean },
              budgeted_spending: { type: :string },
              budgeted_spending_cents: { type: :integer },
              display_budgeted_spending: { type: :string },
              display_budgeted_spending_cents: { type: :integer },
              actual_spending: { type: :string },
              actual_spending_cents: { type: :integer },
              available_to_spend: { type: :string },
              available_to_spend_cents: { type: :integer },
              category: {
                type: :object,
                required: %w[id name color lucide_icon],
                properties: {
                  id: { type: :string, format: :uuid },
                  name: { type: :string },
                  color: { type: :string },
                  lucide_icon: { type: :string },
                  parent_id: { type: :string, format: :uuid, nullable: true }
                }
              },
              created_at: { type: :string, format: :'date-time' },
              updated_at: { type: :string, format: :'date-time' }
            }
          },
          BudgetCategoryCollection: {
            type: :object,
            required: %w[budget_categories pagination],
            properties: {
              budget_categories: {
                type: :array,
                items: { '$ref' => '#/components/schemas/BudgetCategorySummary' }
              },
              pagination: { '$ref' => '#/components/schemas/Pagination' }
            }
          },
          Balance: {
            type: :object,
            required: %w[id date currency flows_factor balance balance_cents start_balance start_balance_cents end_balance end_balance_cents account created_at updated_at],
            properties: {
              id: { type: :string, format: :uuid },
              date: { type: :string, format: :date },
              currency: { type: :string },
              flows_factor: { type: :number, format: :float },
              balance: { type: :string },
              balance_cents: { type: :integer, description: 'Balance in currency minor units' },
              cash_balance: { type: :string, nullable: true },
              cash_balance_cents: { type: :integer, nullable: true, description: 'Cash balance in currency minor units' },
              start_cash_balance: { type: :string },
              start_cash_balance_cents: { type: :integer, description: 'Starting cash balance in currency minor units' },
              start_non_cash_balance: { type: :string },
              start_non_cash_balance_cents: { type: :integer, description: 'Starting non-cash balance in currency minor units' },
              start_balance: { type: :string },
              start_balance_cents: { type: :integer, description: 'Starting total balance in currency minor units' },
              cash_inflows: { type: :string },
              cash_inflows_cents: { type: :integer, description: 'Cash inflows in currency minor units' },
              cash_outflows: { type: :string },
              cash_outflows_cents: { type: :integer, description: 'Cash outflows in currency minor units' },
              non_cash_inflows: { type: :string },
              non_cash_inflows_cents: { type: :integer, description: 'Non-cash inflows in currency minor units' },
              non_cash_outflows: { type: :string },
              non_cash_outflows_cents: { type: :integer, description: 'Non-cash outflows in currency minor units' },
              net_market_flows: { type: :string },
              net_market_flows_cents: { type: :integer, description: 'Net market flows in currency minor units' },
              cash_adjustments: { type: :string },
              cash_adjustments_cents: { type: :integer, description: 'Cash adjustments in currency minor units' },
              non_cash_adjustments: { type: :string },
              non_cash_adjustments_cents: { type: :integer, description: 'Non-cash adjustments in currency minor units' },
              end_cash_balance: { type: :string },
              end_cash_balance_cents: { type: :integer, description: 'Ending cash balance in currency minor units' },
              end_non_cash_balance: { type: :string },
              end_non_cash_balance_cents: { type: :integer, description: 'Ending non-cash balance in currency minor units' },
              end_balance: { type: :string },
              end_balance_cents: { type: :integer, description: 'Ending total balance in currency minor units' },
              account: { '$ref' => '#/components/schemas/BalanceAccount' },
              created_at: { type: :string, format: :'date-time' },
              updated_at: { type: :string, format: :'date-time' }
            }
          },
          BalanceAccount: {
            type: :object,
            required: %w[id name account_type],
            properties: {
              id: { type: :string, format: :uuid },
              name: { type: :string },
              account_type: { type: :string, nullable: true }
            }
          },
          BalanceCollection: {
            type: :object,
            required: %w[balances pagination],
            properties: {
              balances: {
                type: :array,
                items: { '$ref' => '#/components/schemas/Balance' }
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
          CategoryCreateRequest: {
            type: :object,
            required: %w[category],
            properties: {
              category: {
                type: :object,
                required: %w[name],
                properties: {
                  name: { type: :string, description: 'Category name (required, unique within family)' },
                  color: { type: :string, description: 'Hex color code (e.g. #22c55e). Defaults to #6172F3 if omitted; subcategories inherit parent color.' },
                  icon: { type: :string, description: 'Lucide icon name (e.g. "coffee"). Auto-suggested from the name when omitted.' },
                  parent_id: { type: :string, format: :uuid, nullable: true, description: 'Parent category ID. Must belong to the same family. Categories support up to 2 levels of nesting.' }
                }
              }
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
          RuleRun: {
            type: :object,
            required: %w[id rule_id rule_name execution_type status transactions_queued transactions_processed transactions_modified pending_jobs_count executed_at rule created_at updated_at],
            properties: {
              id: { type: :string, format: :uuid },
              rule_id: { type: :string, format: :uuid },
              rule_name: { type: :string, nullable: true },
              execution_type: { type: :string, enum: %w[manual scheduled] },
              status: { type: :string, enum: %w[pending success failed] },
              transactions_queued: { type: :integer, minimum: 0 },
              transactions_processed: { type: :integer, minimum: 0 },
              transactions_modified: { type: :integer, minimum: 0 },
              pending_jobs_count: { type: :integer, minimum: 0 },
              executed_at: { type: :string, format: :'date-time' },
              error_message: { type: :string, nullable: true },
              rule: {
                type: :object,
                nullable: true,
                required: %w[id resource_type active],
                properties: {
                  id: { type: :string, format: :uuid },
                  name: { type: :string, nullable: true },
                  resource_type: { type: :string },
                  active: { type: :boolean }
                }
              },
              created_at: { type: :string, format: :'date-time' },
              updated_at: { type: :string, format: :'date-time' }
            }
          },
          RuleRunResponse: {
            type: :object,
            required: %w[data],
            properties: {
              data: { '$ref' => '#/components/schemas/RuleRun' }
            }
          },
          RuleRunCollection: {
            type: :object,
            required: %w[data meta],
            properties: {
              data: {
                type: :array,
                items: { '$ref' => '#/components/schemas/RuleRun' }
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
          TransferTransactionSide: {
            type: :object,
            required: %w[id entry_id date amount amount_cents currency name kind account],
            properties: {
              id: { type: :string, format: :uuid },
              entry_id: { type: :string, format: :uuid },
              date: { type: :string, format: :date },
              amount: { type: :string },
              amount_cents: { type: :integer, description: 'Signed amount in currency minor units' },
              currency: { type: :string },
              name: { type: :string },
              kind: { type: :string },
              account: {
                type: :object,
                required: %w[id name account_type],
                properties: {
                  id: { type: :string, format: :uuid },
                  name: { type: :string },
                  account_type: { type: :string, nullable: true }
                }
              }
            }
          },
          TransferDecision: {
            type: :object,
            required: %w[id status date amount amount_cents currency transfer_type inflow_transaction outflow_transaction created_at updated_at],
            properties: {
              id: { type: :string, format: :uuid },
              status: { type: :string, enum: %w[pending confirmed] },
              date: { type: :string, format: :date },
              amount: { type: :string },
              amount_cents: { type: :integer, description: 'Absolute transfer amount in currency minor units' },
              currency: { type: :string },
              transfer_type: { type: :string, enum: %w[transfer liability_payment loan_payment] },
              notes: { type: :string, nullable: true },
              inflow_transaction: { '$ref' => '#/components/schemas/TransferTransactionSide' },
              outflow_transaction: { '$ref' => '#/components/schemas/TransferTransactionSide' },
              created_at: { type: :string, format: :'date-time' },
              updated_at: { type: :string, format: :'date-time' }
            }
          },
          TransferDecisionCollection: {
            type: :object,
            required: %w[transfers pagination],
            properties: {
              transfers: {
                type: :array,
                items: { '$ref' => '#/components/schemas/TransferDecision' }
              },
              pagination: { '$ref' => '#/components/schemas/Pagination' }
            }
          },
          RejectedTransfer: {
            type: :object,
            required: %w[id inflow_transaction outflow_transaction created_at updated_at],
            properties: {
              id: { type: :string, format: :uuid },
              inflow_transaction: { '$ref' => '#/components/schemas/TransferTransactionSide' },
              outflow_transaction: { '$ref' => '#/components/schemas/TransferTransactionSide' },
              created_at: { type: :string, format: :'date-time' },
              updated_at: { type: :string, format: :'date-time' }
            }
          },
          RejectedTransferCollection: {
            type: :object,
            required: %w[rejected_transfers pagination],
            properties: {
              rejected_transfers: {
                type: :array,
                items: { '$ref' => '#/components/schemas/RejectedTransfer' }
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
          ProviderConnectionInstitution: {
            type: :object,
            required: %w[name],
            properties: {
              name: { type: :string, nullable: true },
              domain: { type: :string, nullable: true },
              url: { type: :string, nullable: true }
            }
          },
          ProviderConnectionAccounts: {
            type: :object,
            required: %w[total_count linked_count unlinked_count],
            properties: {
              total_count: { type: :integer, minimum: 0 },
              linked_count: { type: :integer, minimum: 0 },
              unlinked_count: { type: :integer, minimum: 0 }
            }
          },
          ProviderConnectionSyncLatest: {
            type: :object,
            required: %w[id status created_at],
            properties: {
              id: { type: :string, format: :uuid },
              status: { type: :string },
              created_at: { type: :string, format: :'date-time' },
              syncing_at: { type: :string, format: :'date-time', nullable: true },
              completed_at: { type: :string, format: :'date-time', nullable: true },
              failed_at: { type: :string, format: :'date-time', nullable: true },
              error: {
                type: :object,
                nullable: true,
                description: "Sanitized latest sync error summary. Null when the latest sync is not failed or stale.",
                required: %w[present],
                properties: {
                  present: { type: :boolean, description: "Always true when this object is present." },
                  message: { type: :string, nullable: true, description: "Stable sanitized error category message; raw provider error text is never exposed." }
                }
              }
            }
          },
          ProviderConnectionSync: {
            type: :object,
            required: %w[syncing],
            properties: {
              syncing: { type: :boolean },
              status_summary: { type: :string, nullable: true },
              last_synced_at: { type: :string, format: :'date-time', nullable: true },
              latest: {
                allOf: [ { '$ref' => '#/components/schemas/ProviderConnectionSyncLatest' } ],
                nullable: true
              }
            }
          },
          ProviderConnection: {
            type: :object,
            required: %w[id provider provider_type name status requires_update credentials_configured scheduled_for_deletion pending_account_setup institution accounts sync created_at updated_at],
            properties: {
              id: { type: :string, format: :uuid },
              provider: { type: :string },
              provider_type: { type: :string },
              name: { type: :string },
              status: { type: :string, nullable: true },
              requires_update: { type: :boolean, nullable: true, description: "False when the provider item does not expose this status." },
              credentials_configured: { type: :boolean, nullable: true, description: "False when credential readiness is unknown." },
              scheduled_for_deletion: { type: :boolean, nullable: true, description: "False when the provider item does not expose this status." },
              pending_account_setup: { type: :boolean, nullable: true, description: "False when account setup state is unknown." },
              institution: { '$ref' => '#/components/schemas/ProviderConnectionInstitution' },
              accounts: { '$ref' => '#/components/schemas/ProviderConnectionAccounts' },
              sync: { '$ref' => '#/components/schemas/ProviderConnectionSync' },
              created_at: { type: :string, format: :'date-time' },
              updated_at: { type: :string, format: :'date-time' }
            }
          },
          ProviderConnectionCollection: {
            type: :object,
            required: %w[data],
            properties: {
              data: {
                type: :array,
                items: { '$ref' => '#/components/schemas/ProviderConnection' }
              }
            }
          },
          ImportRowMapping: {
            type: :object,
            required: %w[key type value create_when_empty creatable mappable],
            properties: {
              key: { type: :string, nullable: true },
              type: { type: :string },
              value: { type: :string, nullable: true },
              create_when_empty: { type: :boolean },
              creatable: { type: :boolean },
              mappable: {
                type: :object,
                nullable: true,
                properties: {
                  id: { type: :string, format: :uuid },
                  type: { type: :string },
                  name: { type: :string, nullable: true }
                }
              }
            }
          },
          ImportRowDiagnostic: {
            type: :object,
            required: %w[id row_number valid errors fields mappings],
            properties: {
              id: { type: :string, format: :uuid },
              row_number: { type: :integer, minimum: 1 },
              valid: { type: :boolean },
              errors: {
                type: :array,
                items: { type: :string }
              },
              fields: {
                type: :object,
                properties: {
                  account: { type: :string, nullable: true },
                  date: { type: :string, nullable: true },
                  qty: { type: :string, nullable: true },
                  ticker: { type: :string, nullable: true },
                  exchange_operating_mic: { type: :string, nullable: true },
                  price: { type: :string, nullable: true },
                  amount: { type: :string, nullable: true },
                  currency: { type: :string, nullable: true },
                  name: { type: :string, nullable: true },
                  category: { type: :string, nullable: true },
                  tags: { type: :string, nullable: true },
                  entity_type: { type: :string, nullable: true },
                  notes: { type: :string, nullable: true },
                  active: { type: :boolean, nullable: true },
                  effective_date: { type: :string, nullable: true },
                  conditions: { type: :string, nullable: true },
                  actions: { type: :string, nullable: true }
                }
              },
              mappings: {
                type: :object,
                properties: {
                  account: { '$ref' => '#/components/schemas/ImportRowMapping' },
                  category: { '$ref' => '#/components/schemas/ImportRowMapping' },
                  account_type: { '$ref' => '#/components/schemas/ImportRowMapping' },
                  tags: {
                    type: :array,
                    items: { '$ref' => '#/components/schemas/ImportRowMapping' }
                  }
                }
              }
            }
          },
          ImportRowDiagnosticCollection: {
            type: :object,
            required: %w[data meta],
            properties: {
              data: {
                type: :array,
                items: { '$ref' => '#/components/schemas/ImportRowDiagnostic' }
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
          SyncableSummary: {
            type: :object,
            required: %w[type id],
            properties: {
              type: { type: :string },
              id: { type: :string, format: :uuid },
              name: { type: :string, nullable: true }
            }
          },
          SyncErrorSummary: {
            type: :object,
            required: %w[message],
            properties: {
              message: { type: :string }
            }
          },
          SyncResource: {
            type: :object,
            required: %w[id status in_progress terminal syncable children_count created_at updated_at],
            properties: {
              id: { type: :string, format: :uuid },
              status: { type: :string, enum: %w[pending syncing completed failed stale] },
              in_progress: { type: :boolean },
              terminal: { type: :boolean },
              syncable: { '$ref' => '#/components/schemas/SyncableSummary' },
              parent_id: { type: :string, format: :uuid, nullable: true },
              children_count: { type: :integer, minimum: 0 },
              window_start_date: { type: :string, format: :date, nullable: true },
              window_end_date: { type: :string, format: :date, nullable: true },
              pending_at: { type: :string, format: :'date-time', nullable: true },
              syncing_at: { type: :string, format: :'date-time', nullable: true },
              completed_at: { type: :string, format: :'date-time', nullable: true },
              failed_at: { type: :string, format: :'date-time', nullable: true },
              error: { nullable: true, allOf: [ { '$ref' => '#/components/schemas/SyncErrorSummary' } ] },
              created_at: { type: :string, format: :'date-time' },
              updated_at: { type: :string, format: :'date-time' }
            }
          },
          SyncResponse: {
            type: :object,
            required: %w[data],
            properties: {
              data: { nullable: true, allOf: [ { '$ref' => '#/components/schemas/SyncResource' } ] }
            }
          },
          SyncCollection: {
            type: :object,
            required: %w[data meta],
            properties: {
              data: {
                type: :array,
                maxItems: 100,
                items: { '$ref' => '#/components/schemas/SyncResource' }
              },
              meta: { '$ref' => '#/components/schemas/Pagination' }
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
          Security: {
            type: :object,
            required: %w[id ticker kind offline created_at updated_at],
            properties: {
              id: { type: :string, format: :uuid },
              ticker: { type: :string },
              name: { type: :string, nullable: true },
              kind: { type: :string, enum: %w[standard cash] },
              country_code: { type: :string, nullable: true },
              exchange_mic: { type: :string, nullable: true },
              exchange_acronym: { type: :string, nullable: true },
              exchange_operating_mic: { type: :string, nullable: true },
              exchange_name: { type: :string, nullable: true },
              offline: { type: :boolean },
              offline_reason: { type: :string, nullable: true },
              website_url: { type: :string, nullable: true },
              logo_url: { type: :string, nullable: true },
              first_provider_price_on: { type: :string, format: :date, nullable: true },
              created_at: { type: :string, format: :'date-time' },
              updated_at: { type: :string, format: :'date-time' }
            }
          },
          SecurityCollection: {
            type: :object,
            required: %w[securities pagination],
            properties: {
              securities: {
                type: :array,
                items: { '$ref' => '#/components/schemas/Security' }
              },
              pagination: { '$ref' => '#/components/schemas/Pagination' }
            }
          },
          SecurityPrice: {
            type: :object,
            required: %w[id date price price_amount currency provisional security created_at updated_at],
            properties: {
              id: { type: :string, format: :uuid },
              date: { type: :string, format: :date },
              price: { type: :string, description: 'Formatted security price' },
              price_amount: { type: :string, description: 'Exact decimal security price' },
              currency: { type: :string },
              provisional: { type: :boolean },
              security: {
                type: :object,
                required: %w[id ticker],
                properties: {
                  id: { type: :string, format: :uuid },
                  ticker: { type: :string },
                  name: { type: :string, nullable: true },
                  exchange_operating_mic: { type: :string, nullable: true }
                }
              },
              created_at: { type: :string, format: :'date-time' },
              updated_at: { type: :string, format: :'date-time' }
            }
          },
          SecurityPriceCollection: {
            type: :object,
            required: %w[security_prices pagination],
            properties: {
              security_prices: {
                type: :array,
                items: { '$ref' => '#/components/schemas/SecurityPrice' }
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
          },
          ResetInitiatedResponse: {
            type: :object,
            required: %w[message status job_id family_id status_url],
            properties: {
              message: { type: :string },
              status: { type: :string, enum: %w[queued] },
              job_id: {
                type: :string,
                description: 'Informational Active Job identifier returned by the queue adapter; reset status is family-scoped, not job-scoped.'
              },
              family_id: { type: :string, format: :uuid, description: 'UUID of the family being reset.' },
              status_url: { type: :string }
            }
          },
          ResetStatusResponse: {
            type: :object,
            required: %w[status family_id reset_complete counts],
            properties: {
              status: {
                type: :string,
                enum: %w[complete data_remaining],
                description: 'Counts-based family reset status at response time.'
              },
              family_id: { type: :string, format: :uuid, description: 'UUID of the family whose reset target counts were checked.' },
              reset_complete: {
                type: :boolean,
                description: 'True when all reset target counts are zero at response time. This is a family data snapshot, not a durable per-job completion record.'
              },
              counts: {
                type: :object,
                required: %w[accounts categories tags merchants plaid_items imports budgets],
                properties: {
                  accounts: { type: :integer, minimum: 0 },
                  categories: { type: :integer, minimum: 0 },
                  tags: { type: :integer, minimum: 0 },
                  merchants: { type: :integer, minimum: 0 },
                  plaid_items: { type: :integer, minimum: 0 },
                  imports: { type: :integer, minimum: 0 },
                  budgets: { type: :integer, minimum: 0 }
                }
              }
            }
          }
        }
      }
    }
  }

  config.openapi_format = :yaml
end
