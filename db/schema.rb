# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[7.2].define(version: 2026_02_18_120001) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pgcrypto"
  enable_extension "plpgsql"

  # Custom types defined in this database.
  # Note that some types may not work with other database engines. Be careful if changing database.
  create_enum "account_status", ["ok", "syncing", "error"]

  create_table "account_providers", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.string "provider_type", null: false
    t.uuid "provider_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "provider_type"], name: "index_account_providers_on_account_and_provider_type", unique: true
    t.index ["provider_type", "provider_id"], name: "index_account_providers_on_provider_type_and_provider_id", unique: true
  end

  create_table "accounts", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "subtype"
    t.uuid "family_id", null: false
    t.string "name"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "accountable_type"
    t.uuid "accountable_id"
    t.decimal "balance", precision: 19, scale: 4
    t.string "currency"
    t.virtual "classification", type: :string, as: "\nCASE\n    WHEN ((accountable_type)::text = ANY (ARRAY[('Loan'::character varying)::text, ('CreditCard'::character varying)::text, ('OtherLiability'::character varying)::text])) THEN 'liability'::text\n    ELSE 'asset'::text\nEND", stored: true
    t.uuid "import_id"
    t.uuid "plaid_account_id"
    t.decimal "cash_balance", precision: 19, scale: 4, default: "0.0"
    t.jsonb "locked_attributes", default: {}
    t.string "status", default: "active"
    t.uuid "simplefin_account_id"
    t.string "institution_name"
    t.string "institution_domain"
    t.text "notes"
    t.jsonb "holdings_snapshot_data"
    t.datetime "holdings_snapshot_at"
    t.index ["accountable_id", "accountable_type"], name: "index_accounts_on_accountable_id_and_accountable_type"
    t.index ["accountable_type"], name: "index_accounts_on_accountable_type"
    t.index ["currency"], name: "index_accounts_on_currency"
    t.index ["family_id", "accountable_type"], name: "index_accounts_on_family_id_and_accountable_type"
    t.index ["family_id", "id"], name: "index_accounts_on_family_id_and_id"
    t.index ["family_id", "status", "accountable_type"], name: "index_accounts_on_family_id_status_accountable_type"
    t.index ["family_id", "status"], name: "index_accounts_on_family_id_and_status"
    t.index ["family_id"], name: "index_accounts_on_family_id"
    t.index ["import_id"], name: "index_accounts_on_import_id"
    t.index ["plaid_account_id"], name: "index_accounts_on_plaid_account_id"
    t.index ["simplefin_account_id"], name: "index_accounts_on_simplefin_account_id"
    t.index ["status"], name: "index_accounts_on_status"
  end

  create_table "active_storage_attachments", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "name", null: false
    t.string "record_type", null: false
    t.uuid "record_id", null: false
    t.uuid "blob_id", null: false
    t.datetime "created_at", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "key", null: false
    t.string "filename", null: false
    t.string "content_type"
    t.text "metadata"
    t.string "service_name", null: false
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.datetime "created_at", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "addresses", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "addressable_type"
    t.uuid "addressable_id"
    t.string "line1"
    t.string "line2"
    t.string "county"
    t.string "locality"
    t.string "region"
    t.string "country"
    t.integer "postal_code"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["addressable_type", "addressable_id"], name: "index_addresses_on_addressable"
  end

  create_table "api_keys", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "name"
    t.uuid "user_id", null: false
    t.json "scopes"
    t.datetime "last_used_at"
    t.datetime "expires_at"
    t.datetime "revoked_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "display_key", null: false
    t.string "source", default: "web"
    t.index ["display_key"], name: "index_api_keys_on_display_key", unique: true
    t.index ["revoked_at"], name: "index_api_keys_on_revoked_at"
    t.index ["user_id", "source"], name: "index_api_keys_on_user_id_and_source"
    t.index ["user_id"], name: "index_api_keys_on_user_id"
  end

  create_table "balances", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.date "date", null: false
    t.decimal "balance", precision: 19, scale: 4, null: false
    t.string "currency", default: "USD", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.decimal "cash_balance", precision: 19, scale: 4, default: "0.0"
    t.decimal "start_cash_balance", precision: 19, scale: 4, default: "0.0", null: false
    t.decimal "start_non_cash_balance", precision: 19, scale: 4, default: "0.0", null: false
    t.decimal "cash_inflows", precision: 19, scale: 4, default: "0.0", null: false
    t.decimal "cash_outflows", precision: 19, scale: 4, default: "0.0", null: false
    t.decimal "non_cash_inflows", precision: 19, scale: 4, default: "0.0", null: false
    t.decimal "non_cash_outflows", precision: 19, scale: 4, default: "0.0", null: false
    t.decimal "net_market_flows", precision: 19, scale: 4, default: "0.0", null: false
    t.decimal "cash_adjustments", precision: 19, scale: 4, default: "0.0", null: false
    t.decimal "non_cash_adjustments", precision: 19, scale: 4, default: "0.0", null: false
    t.integer "flows_factor", default: 1, null: false
    t.virtual "start_balance", type: :decimal, precision: 19, scale: 4, as: "(start_cash_balance + start_non_cash_balance)", stored: true
    t.virtual "end_cash_balance", type: :decimal, precision: 19, scale: 4, as: "((start_cash_balance + ((cash_inflows - cash_outflows) * (flows_factor)::numeric)) + cash_adjustments)", stored: true
    t.virtual "end_non_cash_balance", type: :decimal, precision: 19, scale: 4, as: "(((start_non_cash_balance + ((non_cash_inflows - non_cash_outflows) * (flows_factor)::numeric)) + net_market_flows) + non_cash_adjustments)", stored: true
    t.virtual "end_balance", type: :decimal, precision: 19, scale: 4, as: "(((start_cash_balance + ((cash_inflows - cash_outflows) * (flows_factor)::numeric)) + cash_adjustments) + (((start_non_cash_balance + ((non_cash_inflows - non_cash_outflows) * (flows_factor)::numeric)) + net_market_flows) + non_cash_adjustments))", stored: true
    t.index ["account_id", "date", "currency"], name: "index_account_balances_on_account_id_date_currency_unique", unique: true
    t.index ["account_id", "date"], name: "index_balances_on_account_id_and_date", order: { date: :desc }
    t.index ["account_id"], name: "index_balances_on_account_id"
  end

  create_table "budget_categories", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "budget_id", null: false
    t.uuid "category_id", null: false
    t.decimal "budgeted_spending", precision: 19, scale: 4, null: false
    t.string "currency", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["budget_id", "category_id"], name: "index_budget_categories_on_budget_id_and_category_id", unique: true
    t.index ["budget_id"], name: "index_budget_categories_on_budget_id"
    t.index ["category_id"], name: "index_budget_categories_on_category_id"
  end

  create_table "budgets", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "family_id", null: false
    t.date "start_date", null: false
    t.date "end_date", null: false
    t.decimal "budgeted_spending", precision: 19, scale: 4
    t.decimal "expected_income", precision: 19, scale: 4
    t.string "currency", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["family_id", "start_date", "end_date"], name: "index_budgets_on_family_id_and_start_date_and_end_date", unique: true
    t.index ["family_id"], name: "index_budgets_on_family_id"
  end

  create_table "categories", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "name", null: false
    t.string "color", default: "#6172F3", null: false
    t.uuid "family_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.uuid "parent_id"
    t.string "classification", default: "expense", null: false
    t.string "lucide_icon", default: "shapes", null: false
    t.index ["family_id"], name: "index_categories_on_family_id"
  end

  create_table "chats", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "user_id", null: false
    t.string "title", null: false
    t.string "instructions"
    t.jsonb "error"
    t.string "latest_assistant_response_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id"], name: "index_chats_on_user_id"
  end

  create_table "coinbase_accounts", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "coinbase_item_id", null: false
    t.string "name"
    t.string "account_id"
    t.string "currency"
    t.decimal "current_balance", precision: 19, scale: 4
    t.string "account_status"
    t.string "account_type"
    t.string "provider"
    t.jsonb "institution_metadata"
    t.jsonb "raw_payload"
    t.jsonb "raw_transactions_payload"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_coinbase_accounts_on_account_id"
    t.index ["coinbase_item_id"], name: "index_coinbase_accounts_on_coinbase_item_id"
  end

  create_table "coinbase_items", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "family_id", null: false
    t.string "name"
    t.string "institution_id"
    t.string "institution_name"
    t.string "institution_domain"
    t.string "institution_url"
    t.string "institution_color"
    t.string "status", default: "good"
    t.boolean "scheduled_for_deletion", default: false
    t.boolean "pending_account_setup", default: false
    t.datetime "sync_start_date"
    t.jsonb "raw_payload"
    t.jsonb "raw_institution_payload"
    t.text "api_key"
    t.text "api_secret"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["family_id"], name: "index_coinbase_items_on_family_id"
    t.index ["status"], name: "index_coinbase_items_on_status"
  end

  create_table "coinstats_accounts", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "coinstats_item_id", null: false
    t.string "name"
    t.string "account_id"
    t.string "currency"
    t.decimal "current_balance", precision: 19, scale: 4
    t.string "account_status"
    t.string "account_type"
    t.string "provider"
    t.jsonb "institution_metadata"
    t.jsonb "raw_payload"
    t.jsonb "raw_transactions_payload"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "wallet_address"
    t.index ["coinstats_item_id", "account_id", "wallet_address"], name: "index_coinstats_accounts_on_item_account_and_wallet", unique: true
    t.index ["coinstats_item_id"], name: "index_coinstats_accounts_on_coinstats_item_id"
  end

  create_table "coinstats_items", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "family_id", null: false
    t.string "name"
    t.string "institution_id"
    t.string "institution_name"
    t.string "institution_domain"
    t.string "institution_url"
    t.string "institution_color"
    t.string "status", default: "good"
    t.boolean "scheduled_for_deletion", default: false
    t.boolean "pending_account_setup", default: false
    t.datetime "sync_start_date"
    t.jsonb "raw_payload"
    t.jsonb "raw_institution_payload"
    t.string "api_key", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["family_id"], name: "index_coinstats_items_on_family_id"
    t.index ["status"], name: "index_coinstats_items_on_status"
  end

  create_table "credit_cards", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.decimal "available_credit", precision: 10, scale: 2
    t.decimal "minimum_payment", precision: 10, scale: 2
    t.decimal "apr", precision: 10, scale: 2
    t.date "expiration_date"
    t.decimal "annual_fee", precision: 10, scale: 2
    t.jsonb "locked_attributes", default: {}
    t.string "subtype"
  end

  create_table "cryptos", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.jsonb "locked_attributes", default: {}
    t.string "subtype"
    t.string "tax_treatment", default: "taxable", null: false
  end

  create_table "data_enrichments", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "enrichable_type", null: false
    t.uuid "enrichable_id", null: false
    t.string "source"
    t.string "attribute_name"
    t.jsonb "value"
    t.jsonb "metadata"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["enrichable_id", "enrichable_type", "source", "attribute_name"], name: "idx_on_enrichable_id_enrichable_type_source_attribu_5be5f63e08", unique: true
    t.index ["enrichable_type", "enrichable_id"], name: "index_data_enrichments_on_enrichable"
  end

  create_table "depositories", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.jsonb "locked_attributes", default: {}
    t.string "subtype"
  end

  create_table "enable_banking_accounts", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "enable_banking_item_id", null: false
    t.string "name"
    t.string "account_id"
    t.string "currency"
    t.decimal "current_balance", precision: 19, scale: 4
    t.string "account_status"
    t.string "account_type"
    t.string "provider"
    t.string "iban"
    t.string "uid"
    t.jsonb "institution_metadata"
    t.jsonb "raw_payload"
    t.jsonb "raw_transactions_payload"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_enable_banking_accounts_on_account_id"
    t.index ["enable_banking_item_id"], name: "index_enable_banking_accounts_on_enable_banking_item_id"
  end

  create_table "enable_banking_items", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "family_id", null: false
    t.string "name"
    t.string "institution_id"
    t.string "institution_name"
    t.string "institution_domain"
    t.string "institution_url"
    t.string "institution_color"
    t.string "status", default: "good"
    t.boolean "scheduled_for_deletion", default: false
    t.boolean "pending_account_setup", default: false
    t.datetime "sync_start_date"
    t.jsonb "raw_payload"
    t.jsonb "raw_institution_payload"
    t.string "country_code"
    t.string "application_id"
    t.text "client_certificate"
    t.string "session_id"
    t.datetime "session_expires_at"
    t.string "aspsp_name"
    t.string "aspsp_id"
    t.string "authorization_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["family_id"], name: "index_enable_banking_items_on_family_id"
    t.index ["status"], name: "index_enable_banking_items_on_status"
  end

  create_table "entries", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.string "entryable_type"
    t.uuid "entryable_id"
    t.decimal "amount", precision: 19, scale: 4, null: false
    t.string "currency"
    t.date "date"
    t.string "name", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.uuid "import_id"
    t.text "notes"
    t.boolean "excluded", default: false
    t.string "plaid_id"
    t.jsonb "locked_attributes", default: {}
    t.string "external_id"
    t.string "source"
    t.boolean "user_modified", default: false, null: false
    t.boolean "import_locked", default: false, null: false
    t.index "lower((name)::text)", name: "index_entries_on_lower_name"
    t.index ["account_id", "date"], name: "index_entries_on_account_id_and_date"
    t.index ["account_id", "source", "external_id"], name: "index_entries_on_account_source_and_external_id", unique: true, where: "((external_id IS NOT NULL) AND (source IS NOT NULL))"
    t.index ["account_id"], name: "index_entries_on_account_id"
    t.index ["date"], name: "index_entries_on_date"
    t.index ["entryable_type"], name: "index_entries_on_entryable_type"
    t.index ["import_id"], name: "index_entries_on_import_id"
    t.index ["import_locked"], name: "index_entries_on_import_locked_true", where: "(import_locked = true)"
    t.index ["user_modified"], name: "index_entries_on_user_modified_true", where: "(user_modified = true)"
  end

  create_table "eval_datasets", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "name", null: false
    t.string "description"
    t.string "eval_type", null: false
    t.string "version", default: "1.0", null: false
    t.integer "sample_count", default: 0
    t.jsonb "metadata", default: {}
    t.boolean "active", default: true
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["eval_type", "active"], name: "index_eval_datasets_on_eval_type_and_active"
    t.index ["name"], name: "index_eval_datasets_on_name", unique: true
  end

  create_table "eval_results", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "eval_run_id", null: false
    t.uuid "eval_sample_id", null: false
    t.jsonb "actual_output", null: false
    t.boolean "correct", null: false
    t.boolean "exact_match", default: false
    t.boolean "hierarchical_match", default: false
    t.boolean "null_expected", default: false
    t.boolean "null_returned", default: false
    t.float "fuzzy_score"
    t.integer "latency_ms"
    t.integer "prompt_tokens"
    t.integer "completion_tokens"
    t.decimal "cost", precision: 10, scale: 6
    t.jsonb "metadata", default: {}
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "alternative_match", default: false
    t.index ["eval_run_id", "correct"], name: "index_eval_results_on_eval_run_id_and_correct"
    t.index ["eval_run_id"], name: "index_eval_results_on_eval_run_id"
    t.index ["eval_sample_id"], name: "index_eval_results_on_eval_sample_id"
  end

  create_table "eval_runs", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "eval_dataset_id", null: false
    t.string "name"
    t.string "status", default: "pending", null: false
    t.string "provider", null: false
    t.string "model", null: false
    t.jsonb "provider_config", default: {}
    t.jsonb "metrics", default: {}
    t.integer "total_prompt_tokens", default: 0
    t.integer "total_completion_tokens", default: 0
    t.decimal "total_cost", precision: 10, scale: 6, default: "0.0"
    t.datetime "started_at"
    t.datetime "completed_at"
    t.text "error_message"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["eval_dataset_id", "model"], name: "index_eval_runs_on_eval_dataset_id_and_model"
    t.index ["eval_dataset_id"], name: "index_eval_runs_on_eval_dataset_id"
    t.index ["provider", "model"], name: "index_eval_runs_on_provider_and_model"
    t.index ["status"], name: "index_eval_runs_on_status"
  end

  create_table "eval_samples", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "eval_dataset_id", null: false
    t.jsonb "input_data", null: false
    t.jsonb "expected_output", null: false
    t.jsonb "context_data", default: {}
    t.string "difficulty", default: "medium"
    t.string "tags", default: [], array: true
    t.jsonb "metadata", default: {}
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["eval_dataset_id", "difficulty"], name: "index_eval_samples_on_eval_dataset_id_and_difficulty"
    t.index ["eval_dataset_id"], name: "index_eval_samples_on_eval_dataset_id"
    t.index ["tags"], name: "index_eval_samples_on_tags", using: :gin
  end

  create_table "exchange_rates", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "from_currency", null: false
    t.string "to_currency", null: false
    t.decimal "rate", null: false
    t.date "date", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["from_currency", "to_currency", "date"], name: "index_exchange_rates_on_base_converted_date_unique", unique: true
    t.index ["from_currency"], name: "index_exchange_rates_on_from_currency"
    t.index ["to_currency"], name: "index_exchange_rates_on_to_currency"
  end

  create_table "families", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "name"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "currency", default: "USD"
    t.string "locale", default: "en"
    t.string "stripe_customer_id"
    t.string "date_format", default: "%m-%d-%Y"
    t.string "country", default: "US"
    t.string "timezone"
    t.boolean "data_enrichment_enabled", default: false
    t.boolean "early_access", default: false
    t.boolean "auto_sync_on_login", default: true, null: false
    t.datetime "latest_sync_activity_at", default: -> { "CURRENT_TIMESTAMP" }
    t.datetime "latest_sync_completed_at", default: -> { "CURRENT_TIMESTAMP" }
    t.boolean "recurring_transactions_disabled", default: false, null: false
    t.integer "month_start_day", default: 1, null: false
    t.string "vector_store_id"
    t.string "moniker", default: "Family", null: false
    t.string "assistant_type", default: "builtin", null: false
    t.check_constraint "month_start_day >= 1 AND month_start_day <= 28", name: "month_start_day_range"
  end

  create_table "family_documents", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "family_id", null: false
    t.string "filename", null: false
    t.string "content_type"
    t.integer "file_size"
    t.string "provider_file_id"
    t.string "status", default: "pending", null: false
    t.jsonb "metadata", default: {}
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["family_id"], name: "index_family_documents_on_family_id"
    t.index ["provider_file_id"], name: "index_family_documents_on_provider_file_id"
    t.index ["status"], name: "index_family_documents_on_status"
  end

  create_table "family_exports", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "family_id", null: false
    t.string "status", default: "pending", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["family_id"], name: "index_family_exports_on_family_id"
  end

  create_table "family_merchant_associations", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "family_id", null: false
    t.uuid "merchant_id", null: false
    t.datetime "unlinked_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["family_id", "merchant_id"], name: "idx_on_family_id_merchant_id_23e883e08f", unique: true
    t.index ["family_id"], name: "index_family_merchant_associations_on_family_id"
    t.index ["merchant_id"], name: "index_family_merchant_associations_on_merchant_id"
  end

  create_table "holdings", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.uuid "security_id", null: false
    t.date "date", null: false
    t.decimal "qty", precision: 19, scale: 4, null: false
    t.decimal "price", precision: 19, scale: 4, null: false
    t.decimal "amount", precision: 19, scale: 4, null: false
    t.string "currency", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "external_id"
    t.decimal "cost_basis", precision: 19, scale: 4
    t.uuid "account_provider_id"
    t.string "cost_basis_source"
    t.boolean "cost_basis_locked", default: false, null: false
    t.uuid "provider_security_id"
    t.boolean "security_locked", default: false, null: false
    t.index ["account_id", "external_id"], name: "idx_holdings_on_account_id_external_id_unique", unique: true, where: "(external_id IS NOT NULL)"
    t.index ["account_id", "security_id", "date", "currency"], name: "idx_on_account_id_security_id_date_currency_5323e39f8b", unique: true
    t.index ["account_id"], name: "index_holdings_on_account_id"
    t.index ["account_provider_id"], name: "index_holdings_on_account_provider_id"
    t.index ["provider_security_id"], name: "index_holdings_on_provider_security_id"
    t.index ["security_id"], name: "index_holdings_on_security_id"
  end

  create_table "impersonation_session_logs", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "impersonation_session_id", null: false
    t.string "controller"
    t.string "action"
    t.text "path"
    t.string "method"
    t.string "ip_address"
    t.text "user_agent"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["impersonation_session_id"], name: "index_impersonation_session_logs_on_impersonation_session_id"
  end

  create_table "impersonation_sessions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "impersonator_id", null: false
    t.uuid "impersonated_id", null: false
    t.string "status", default: "pending", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["impersonated_id"], name: "index_impersonation_sessions_on_impersonated_id"
    t.index ["impersonator_id"], name: "index_impersonation_sessions_on_impersonator_id"
  end

  create_table "import_mappings", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "type", null: false
    t.string "key"
    t.string "value"
    t.boolean "create_when_empty", default: true
    t.uuid "import_id", null: false
    t.string "mappable_type"
    t.uuid "mappable_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["import_id"], name: "index_import_mappings_on_import_id"
    t.index ["mappable_type", "mappable_id"], name: "index_import_mappings_on_mappable"
  end

  create_table "import_rows", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "import_id", null: false
    t.string "account"
    t.string "date"
    t.string "qty"
    t.string "ticker"
    t.string "price"
    t.string "amount"
    t.string "currency"
    t.string "name"
    t.string "category"
    t.string "tags"
    t.string "entity_type"
    t.text "notes"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "exchange_operating_mic"
    t.string "category_parent"
    t.string "category_color"
    t.string "category_classification"
    t.string "category_icon"
    t.string "resource_type"
    t.boolean "active"
    t.string "effective_date"
    t.text "conditions"
    t.text "actions"
    t.index ["import_id"], name: "index_import_rows_on_import_id"
  end

  create_table "imports", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.jsonb "column_mappings"
    t.string "status"
    t.string "raw_file_str"
    t.string "normalized_csv_str"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "col_sep", default: ","
    t.uuid "family_id", null: false
    t.uuid "account_id"
    t.string "type", null: false
    t.string "date_col_label"
    t.string "amount_col_label"
    t.string "name_col_label"
    t.string "category_col_label"
    t.string "tags_col_label"
    t.string "account_col_label"
    t.string "qty_col_label"
    t.string "ticker_col_label"
    t.string "price_col_label"
    t.string "entity_type_col_label"
    t.string "notes_col_label"
    t.string "currency_col_label"
    t.string "date_format", default: "%m/%d/%Y"
    t.string "signage_convention", default: "inflows_positive"
    t.string "error"
    t.string "number_format"
    t.string "exchange_operating_mic_col_label"
    t.string "amount_type_strategy", default: "signed_amount"
    t.string "amount_type_inflow_value"
    t.integer "rows_to_skip", default: 0, null: false
    t.integer "rows_count", default: 0, null: false
    t.string "amount_type_identifier_value"
    t.text "ai_summary"
    t.string "document_type"
    t.jsonb "extracted_data"
    t.index ["family_id"], name: "index_imports_on_family_id"
  end

  create_table "indexa_capital_accounts", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "indexa_capital_item_id", null: false
    t.string "name"
    t.string "indexa_capital_account_id"
    t.string "account_number"
    t.string "currency"
    t.decimal "current_balance", precision: 19, scale: 4
    t.string "account_status"
    t.string "account_type"
    t.string "provider"
    t.jsonb "institution_metadata"
    t.jsonb "raw_payload"
    t.string "indexa_capital_authorization_id"
    t.decimal "cash_balance", precision: 19, scale: 4, default: "0.0"
    t.jsonb "raw_holdings_payload", default: []
    t.jsonb "raw_activities_payload", default: []
    t.datetime "last_holdings_sync"
    t.datetime "last_activities_sync"
    t.boolean "activities_fetch_pending", default: false
    t.date "sync_start_date"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["indexa_capital_account_id"], name: "index_indexa_capital_accounts_on_indexa_capital_account_id", unique: true
    t.index ["indexa_capital_authorization_id"], name: "idx_on_indexa_capital_authorization_id_58db208d52"
    t.index ["indexa_capital_item_id"], name: "index_indexa_capital_accounts_on_indexa_capital_item_id"
  end

  create_table "indexa_capital_items", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "family_id", null: false
    t.string "name"
    t.string "institution_id"
    t.string "institution_name"
    t.string "institution_domain"
    t.string "institution_url"
    t.string "institution_color"
    t.string "status", default: "good"
    t.boolean "scheduled_for_deletion", default: false
    t.boolean "pending_account_setup", default: false
    t.datetime "sync_start_date"
    t.jsonb "raw_payload"
    t.jsonb "raw_institution_payload"
    t.string "username"
    t.string "document"
    t.text "password"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.text "api_token"
    t.index ["family_id"], name: "index_indexa_capital_items_on_family_id"
    t.index ["status"], name: "index_indexa_capital_items_on_status"
  end

  create_table "investments", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.jsonb "locked_attributes", default: {}
    t.string "subtype"
  end

  create_table "invitations", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "email"
    t.string "role"
    t.string "token"
    t.uuid "family_id", null: false
    t.uuid "inviter_id", null: false
    t.datetime "accepted_at"
    t.datetime "expires_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "token_digest"
    t.index ["email", "family_id"], name: "index_invitations_on_email_and_family_id", unique: true
    t.index ["email"], name: "index_invitations_on_email"
    t.index ["family_id"], name: "index_invitations_on_family_id"
    t.index ["inviter_id"], name: "index_invitations_on_inviter_id"
    t.index ["token"], name: "index_invitations_on_token", unique: true
    t.index ["token_digest"], name: "index_invitations_on_token_digest", unique: true, where: "(token_digest IS NOT NULL)"
  end

  create_table "invite_codes", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "token", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "token_digest"
    t.index ["token"], name: "index_invite_codes_on_token", unique: true
    t.index ["token_digest"], name: "index_invite_codes_on_token_digest", unique: true, where: "(token_digest IS NOT NULL)"
  end

  create_table "llm_usages", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "family_id", null: false
    t.string "provider", null: false
    t.string "model", null: false
    t.string "operation", null: false
    t.integer "prompt_tokens", default: 0, null: false
    t.integer "completion_tokens", default: 0, null: false
    t.integer "total_tokens", default: 0, null: false
    t.decimal "estimated_cost", precision: 10, scale: 6
    t.jsonb "metadata", default: {}
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["family_id", "created_at"], name: "index_llm_usages_on_family_id_and_created_at"
    t.index ["family_id", "operation"], name: "index_llm_usages_on_family_id_and_operation"
    t.index ["family_id"], name: "index_llm_usages_on_family_id"
  end

  create_table "loans", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "rate_type"
    t.decimal "interest_rate", precision: 10, scale: 3
    t.integer "term_months"
    t.decimal "initial_balance", precision: 19, scale: 4
    t.jsonb "locked_attributes", default: {}
    t.string "subtype"
  end

  create_table "lunchflow_accounts", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "lunchflow_item_id", null: false
    t.string "name"
    t.string "account_id"
    t.string "currency"
    t.decimal "current_balance", precision: 19, scale: 4
    t.string "account_status"
    t.string "provider"
    t.string "account_type"
    t.jsonb "institution_metadata"
    t.jsonb "raw_payload"
    t.jsonb "raw_transactions_payload"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "holdings_supported", default: true, null: false
    t.jsonb "raw_holdings_payload"
    t.index ["account_id"], name: "index_lunchflow_accounts_on_account_id"
    t.index ["lunchflow_item_id"], name: "index_lunchflow_accounts_on_lunchflow_item_id"
  end

  create_table "lunchflow_items", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "family_id", null: false
    t.string "name"
    t.string "institution_id"
    t.string "institution_name"
    t.string "institution_domain"
    t.string "institution_url"
    t.string "institution_color"
    t.string "status", default: "good"
    t.boolean "scheduled_for_deletion", default: false
    t.boolean "pending_account_setup", default: false
    t.datetime "sync_start_date"
    t.jsonb "raw_payload"
    t.jsonb "raw_institution_payload"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.text "api_key"
    t.string "base_url"
    t.index ["family_id"], name: "index_lunchflow_items_on_family_id"
    t.index ["status"], name: "index_lunchflow_items_on_status"
  end

  create_table "merchants", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "name", null: false
    t.string "color"
    t.uuid "family_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "logo_url"
    t.string "website_url"
    t.string "type", null: false
    t.string "source"
    t.string "provider_merchant_id"
    t.index ["family_id", "name"], name: "index_merchants_on_family_id_and_name", unique: true, where: "((type)::text = 'FamilyMerchant'::text)"
    t.index ["family_id"], name: "index_merchants_on_family_id"
    t.index ["provider_merchant_id", "source"], name: "index_merchants_on_provider_merchant_id_and_source", unique: true, where: "((provider_merchant_id IS NOT NULL) AND ((type)::text = 'ProviderMerchant'::text))"
    t.index ["source", "name"], name: "index_merchants_on_source_and_name", unique: true, where: "((type)::text = 'ProviderMerchant'::text)"
    t.index ["type"], name: "index_merchants_on_type"
  end

  create_table "mercury_accounts", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "mercury_item_id", null: false
    t.string "name"
    t.string "account_id", null: false
    t.string "currency"
    t.decimal "current_balance", precision: 19, scale: 4
    t.string "account_status"
    t.string "account_type"
    t.string "provider"
    t.jsonb "institution_metadata"
    t.jsonb "raw_payload"
    t.jsonb "raw_transactions_payload"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_mercury_accounts_on_account_id", unique: true
    t.index ["mercury_item_id"], name: "index_mercury_accounts_on_mercury_item_id"
  end

  create_table "mercury_items", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "family_id", null: false
    t.string "name"
    t.string "institution_id"
    t.string "institution_name"
    t.string "institution_domain"
    t.string "institution_url"
    t.string "institution_color"
    t.string "status", default: "good"
    t.boolean "scheduled_for_deletion", default: false
    t.boolean "pending_account_setup", default: false
    t.datetime "sync_start_date"
    t.jsonb "raw_payload"
    t.jsonb "raw_institution_payload"
    t.text "token"
    t.string "base_url"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["family_id"], name: "index_mercury_items_on_family_id"
    t.index ["status"], name: "index_mercury_items_on_status"
  end

  create_table "messages", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "chat_id", null: false
    t.string "type", null: false
    t.string "status", default: "complete", null: false
    t.text "content"
    t.string "ai_model"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "debug", default: false
    t.string "provider_id"
    t.boolean "reasoning", default: false
    t.index ["chat_id"], name: "index_messages_on_chat_id"
  end

  create_table "mobile_devices", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "user_id", null: false
    t.string "device_id"
    t.string "device_name"
    t.string "device_type"
    t.string "os_version"
    t.string "app_version"
    t.datetime "last_seen_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id", "device_id"], name: "index_mobile_devices_on_user_id_and_device_id", unique: true
    t.index ["user_id"], name: "index_mobile_devices_on_user_id"
  end

  create_table "oauth_access_grants", force: :cascade do |t|
    t.string "resource_owner_id", null: false
    t.bigint "application_id", null: false
    t.string "token", null: false
    t.integer "expires_in", null: false
    t.text "redirect_uri", null: false
    t.string "scopes", default: "", null: false
    t.datetime "created_at", null: false
    t.datetime "revoked_at"
    t.index ["application_id"], name: "index_oauth_access_grants_on_application_id"
    t.index ["resource_owner_id"], name: "index_oauth_access_grants_on_resource_owner_id"
    t.index ["token"], name: "index_oauth_access_grants_on_token", unique: true
  end

  create_table "oauth_access_tokens", force: :cascade do |t|
    t.string "resource_owner_id"
    t.bigint "application_id", null: false
    t.string "token", null: false
    t.string "refresh_token"
    t.integer "expires_in"
    t.string "scopes"
    t.datetime "created_at", null: false
    t.datetime "revoked_at"
    t.string "previous_refresh_token", default: "", null: false
    t.uuid "mobile_device_id"
    t.index ["application_id"], name: "index_oauth_access_tokens_on_application_id"
    t.index ["mobile_device_id"], name: "index_oauth_access_tokens_on_mobile_device_id"
    t.index ["refresh_token"], name: "index_oauth_access_tokens_on_refresh_token", unique: true
    t.index ["resource_owner_id"], name: "index_oauth_access_tokens_on_resource_owner_id"
    t.index ["token"], name: "index_oauth_access_tokens_on_token", unique: true
  end

  create_table "oauth_applications", force: :cascade do |t|
    t.string "name", null: false
    t.string "uid", null: false
    t.string "secret", null: false
    t.text "redirect_uri", null: false
    t.string "scopes", default: "", null: false
    t.boolean "confidential", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.uuid "owner_id"
    t.string "owner_type"
    t.index ["owner_id", "owner_type"], name: "index_oauth_applications_on_owner_id_and_owner_type"
    t.index ["uid"], name: "index_oauth_applications_on_uid", unique: true
  end

  create_table "oidc_identities", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "user_id", null: false
    t.string "provider", null: false
    t.string "uid", null: false
    t.jsonb "info", default: {}
    t.datetime "last_authenticated_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "issuer"
    t.index ["issuer"], name: "index_oidc_identities_on_issuer"
    t.index ["provider", "uid"], name: "index_oidc_identities_on_provider_and_uid", unique: true
    t.index ["user_id"], name: "index_oidc_identities_on_user_id"
  end

  create_table "other_assets", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.jsonb "locked_attributes", default: {}
    t.string "subtype"
  end

  create_table "other_liabilities", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.jsonb "locked_attributes", default: {}
    t.string "subtype"
  end

  create_table "plaid_accounts", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "plaid_item_id", null: false
    t.string "plaid_id", null: false
    t.string "plaid_type", null: false
    t.string "plaid_subtype"
    t.decimal "current_balance", precision: 19, scale: 4
    t.decimal "available_balance", precision: 19, scale: 4
    t.string "currency", null: false
    t.string "name", null: false
    t.string "mask"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.jsonb "raw_payload", default: {}
    t.jsonb "raw_transactions_payload", default: {}
    t.jsonb "raw_holdings_payload", default: {}
    t.jsonb "raw_liabilities_payload", default: {}
    t.index ["plaid_id"], name: "index_plaid_accounts_on_plaid_id", unique: true
    t.index ["plaid_item_id"], name: "index_plaid_accounts_on_plaid_item_id"
  end

  create_table "plaid_items", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "family_id", null: false
    t.string "access_token"
    t.string "plaid_id", null: false
    t.string "name"
    t.string "next_cursor"
    t.boolean "scheduled_for_deletion", default: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "available_products", default: [], array: true
    t.string "billed_products", default: [], array: true
    t.string "plaid_region", default: "us", null: false
    t.string "institution_url"
    t.string "institution_id"
    t.string "institution_color"
    t.string "status", default: "good", null: false
    t.jsonb "raw_payload", default: {}
    t.jsonb "raw_institution_payload", default: {}
    t.index ["family_id"], name: "index_plaid_items_on_family_id"
    t.index ["plaid_id"], name: "index_plaid_items_on_plaid_id", unique: true
  end

  create_table "properties", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "year_built"
    t.integer "area_value"
    t.string "area_unit"
    t.jsonb "locked_attributes", default: {}
    t.string "subtype"
  end

  create_table "recurring_transactions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "family_id", null: false
    t.uuid "merchant_id"
    t.decimal "amount", precision: 19, scale: 4, null: false
    t.string "currency", null: false
    t.integer "expected_day_of_month", null: false
    t.date "last_occurrence_date", null: false
    t.date "next_expected_date", null: false
    t.string "status", default: "active", null: false
    t.integer "occurrence_count", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "name"
    t.boolean "manual", default: false, null: false
    t.decimal "expected_amount_min", precision: 19, scale: 4
    t.decimal "expected_amount_max", precision: 19, scale: 4
    t.decimal "expected_amount_avg", precision: 19, scale: 4
    t.index ["family_id", "merchant_id", "amount", "currency"], name: "idx_recurring_txns_merchant", unique: true, where: "(merchant_id IS NOT NULL)"
    t.index ["family_id", "name", "amount", "currency"], name: "idx_recurring_txns_name", unique: true, where: "((name IS NOT NULL) AND (merchant_id IS NULL))"
    t.index ["family_id", "status"], name: "index_recurring_transactions_on_family_id_and_status"
    t.index ["family_id"], name: "index_recurring_transactions_on_family_id"
    t.index ["merchant_id"], name: "index_recurring_transactions_on_merchant_id"
    t.index ["next_expected_date"], name: "index_recurring_transactions_on_next_expected_date"
  end

  create_table "rejected_transfers", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "inflow_transaction_id", null: false
    t.uuid "outflow_transaction_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["inflow_transaction_id", "outflow_transaction_id"], name: "idx_on_inflow_transaction_id_outflow_transaction_id_412f8e7e26", unique: true
    t.index ["inflow_transaction_id"], name: "index_rejected_transfers_on_inflow_transaction_id"
    t.index ["outflow_transaction_id"], name: "index_rejected_transfers_on_outflow_transaction_id"
  end

  create_table "rule_actions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "rule_id", null: false
    t.string "action_type", null: false
    t.string "value"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["rule_id"], name: "index_rule_actions_on_rule_id"
  end

  create_table "rule_conditions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "rule_id"
    t.uuid "parent_id"
    t.string "condition_type", null: false
    t.string "operator", null: false
    t.string "value"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["parent_id"], name: "index_rule_conditions_on_parent_id"
    t.index ["rule_id"], name: "index_rule_conditions_on_rule_id"
  end

  create_table "rule_runs", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "rule_id", null: false
    t.string "rule_name"
    t.string "execution_type", null: false
    t.string "status", null: false
    t.integer "transactions_queued", default: 0, null: false
    t.integer "transactions_processed", default: 0, null: false
    t.integer "transactions_modified", default: 0, null: false
    t.integer "pending_jobs_count", default: 0, null: false
    t.datetime "executed_at", null: false
    t.text "error_message"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["executed_at"], name: "index_rule_runs_on_executed_at"
    t.index ["rule_id", "executed_at"], name: "index_rule_runs_on_rule_id_and_executed_at"
    t.index ["rule_id"], name: "index_rule_runs_on_rule_id"
  end

  create_table "rules", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "family_id", null: false
    t.string "resource_type", null: false
    t.date "effective_date"
    t.boolean "active", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "name"
    t.index ["family_id"], name: "index_rules_on_family_id"
  end

  create_table "securities", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "ticker", null: false
    t.string "name"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "country_code"
    t.string "exchange_mic"
    t.string "exchange_acronym"
    t.string "logo_url"
    t.string "exchange_operating_mic"
    t.boolean "offline", default: false, null: false
    t.datetime "failed_fetch_at"
    t.integer "failed_fetch_count", default: 0, null: false
    t.datetime "last_health_check_at"
    t.string "website_url"
    t.index "upper((ticker)::text), COALESCE(upper((exchange_operating_mic)::text), ''::text)", name: "index_securities_on_ticker_and_exchange_operating_mic_unique", unique: true
    t.index ["country_code"], name: "index_securities_on_country_code"
    t.index ["exchange_operating_mic"], name: "index_securities_on_exchange_operating_mic"
  end

  create_table "security_prices", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.date "date", null: false
    t.decimal "price", precision: 19, scale: 4, null: false
    t.string "currency", default: "USD", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.uuid "security_id"
    t.boolean "provisional", default: false, null: false
    t.index ["security_id", "date", "currency"], name: "index_security_prices_on_security_id_and_date_and_currency", unique: true
    t.index ["security_id"], name: "index_security_prices_on_security_id"
  end

  create_table "sessions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "user_id", null: false
    t.string "user_agent"
    t.string "ip_address"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.uuid "active_impersonator_session_id"
    t.datetime "subscribed_at"
    t.jsonb "prev_transaction_page_params", default: {}
    t.jsonb "data", default: {}
    t.string "ip_address_digest"
    t.index ["active_impersonator_session_id"], name: "index_sessions_on_active_impersonator_session_id"
    t.index ["ip_address_digest"], name: "index_sessions_on_ip_address_digest"
    t.index ["user_id"], name: "index_sessions_on_user_id"
  end

  create_table "settings", force: :cascade do |t|
    t.string "var", null: false
    t.text "value"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["var"], name: "index_settings_on_var", unique: true
  end

  create_table "simplefin_accounts", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "simplefin_item_id", null: false
    t.string "name"
    t.string "account_id"
    t.string "currency"
    t.decimal "current_balance", precision: 19, scale: 4
    t.decimal "available_balance", precision: 19, scale: 4
    t.string "account_type"
    t.string "account_subtype"
    t.jsonb "raw_payload"
    t.jsonb "raw_transactions_payload"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "balance_date"
    t.jsonb "extra"
    t.jsonb "org_data"
    t.jsonb "raw_holdings_payload"
    t.index ["account_id"], name: "index_simplefin_accounts_on_account_id"
    t.index ["simplefin_item_id", "account_id"], name: "idx_unique_sfa_per_item_and_upstream", unique: true, where: "(account_id IS NOT NULL)"
    t.index ["simplefin_item_id"], name: "index_simplefin_accounts_on_simplefin_item_id"
  end

  create_table "simplefin_items", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "family_id", null: false
    t.text "access_url"
    t.string "name"
    t.string "institution_id"
    t.string "institution_name"
    t.string "institution_url"
    t.string "status", default: "good"
    t.boolean "scheduled_for_deletion", default: false
    t.jsonb "raw_payload"
    t.jsonb "raw_institution_payload"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "pending_account_setup", default: false, null: false
    t.string "institution_domain"
    t.string "institution_color"
    t.date "sync_start_date"
    t.index ["family_id"], name: "index_simplefin_items_on_family_id"
    t.index ["institution_domain"], name: "index_simplefin_items_on_institution_domain"
    t.index ["institution_id"], name: "index_simplefin_items_on_institution_id"
    t.index ["institution_name"], name: "index_simplefin_items_on_institution_name"
    t.index ["status"], name: "index_simplefin_items_on_status"
  end

  create_table "snaptrade_accounts", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "snaptrade_item_id", null: false
    t.string "name"
    t.string "account_id"
    t.string "snaptrade_account_id"
    t.string "snaptrade_authorization_id"
    t.string "account_number"
    t.string "brokerage_name"
    t.string "currency"
    t.decimal "current_balance", precision: 19, scale: 4
    t.decimal "cash_balance", precision: 19, scale: 4
    t.string "account_status"
    t.string "account_type"
    t.string "provider"
    t.jsonb "institution_metadata"
    t.jsonb "raw_payload"
    t.jsonb "raw_transactions_payload"
    t.jsonb "raw_holdings_payload", default: []
    t.jsonb "raw_activities_payload", default: []
    t.datetime "last_holdings_sync"
    t.datetime "last_activities_sync"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "activities_fetch_pending", default: false
    t.date "sync_start_date"
    t.index ["account_id"], name: "index_snaptrade_accounts_on_account_id", unique: true
    t.index ["snaptrade_account_id"], name: "index_snaptrade_accounts_on_snaptrade_account_id", unique: true
    t.index ["snaptrade_item_id"], name: "index_snaptrade_accounts_on_snaptrade_item_id"
  end

  create_table "snaptrade_items", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "family_id", null: false
    t.string "name"
    t.string "institution_id"
    t.string "institution_name"
    t.string "institution_domain"
    t.string "institution_url"
    t.string "institution_color"
    t.string "status", default: "good"
    t.boolean "scheduled_for_deletion", default: false
    t.boolean "pending_account_setup", default: false
    t.datetime "sync_start_date"
    t.datetime "last_synced_at"
    t.jsonb "raw_payload"
    t.jsonb "raw_institution_payload"
    t.string "client_id"
    t.string "consumer_key"
    t.string "snaptrade_user_id"
    t.string "snaptrade_user_secret"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["family_id"], name: "index_snaptrade_items_on_family_id"
    t.index ["status"], name: "index_snaptrade_items_on_status"
  end

  create_table "sso_audit_logs", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "user_id"
    t.string "event_type", null: false
    t.string "provider"
    t.string "ip_address"
    t.string "user_agent"
    t.jsonb "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["created_at"], name: "index_sso_audit_logs_on_created_at"
    t.index ["event_type"], name: "index_sso_audit_logs_on_event_type"
    t.index ["user_id", "created_at"], name: "index_sso_audit_logs_on_user_id_and_created_at"
    t.index ["user_id"], name: "index_sso_audit_logs_on_user_id"
  end

  create_table "sso_providers", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "strategy", null: false
    t.string "name", null: false
    t.string "label", null: false
    t.string "icon"
    t.boolean "enabled", default: true, null: false
    t.string "issuer"
    t.string "client_id"
    t.string "client_secret"
    t.string "redirect_uri"
    t.jsonb "settings", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["enabled"], name: "index_sso_providers_on_enabled"
    t.index ["name"], name: "index_sso_providers_on_name", unique: true
  end

  create_table "subscriptions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "family_id", null: false
    t.string "status", null: false
    t.string "stripe_id"
    t.decimal "amount", precision: 19, scale: 4
    t.string "currency"
    t.string "interval"
    t.datetime "current_period_ends_at"
    t.datetime "trial_ends_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "cancel_at_period_end", default: false, null: false
    t.index ["family_id"], name: "index_subscriptions_on_family_id", unique: true
  end

  create_table "syncs", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "syncable_type", null: false
    t.uuid "syncable_id", null: false
    t.string "status", default: "pending"
    t.string "error"
    t.jsonb "data"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.uuid "parent_id"
    t.datetime "pending_at"
    t.datetime "syncing_at"
    t.datetime "completed_at"
    t.datetime "failed_at"
    t.date "window_start_date"
    t.date "window_end_date"
    t.text "sync_stats"
    t.index ["parent_id"], name: "index_syncs_on_parent_id"
    t.index ["status"], name: "index_syncs_on_status"
    t.index ["syncable_type", "syncable_id"], name: "index_syncs_on_syncable"
  end

  create_table "taggings", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "tag_id", null: false
    t.string "taggable_type"
    t.uuid "taggable_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["tag_id"], name: "index_taggings_on_tag_id"
    t.index ["taggable_type", "taggable_id"], name: "index_taggings_on_taggable"
  end

  create_table "tags", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "name"
    t.string "color", default: "#e99537", null: false
    t.uuid "family_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["family_id"], name: "index_tags_on_family_id"
  end

  create_table "tool_calls", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "message_id", null: false
    t.string "provider_id", null: false
    t.string "provider_call_id"
    t.string "type", null: false
    t.string "function_name"
    t.jsonb "function_arguments"
    t.jsonb "function_result"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["message_id"], name: "index_tool_calls_on_message_id"
  end

  create_table "trades", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "security_id", null: false
    t.decimal "qty", precision: 19, scale: 4
    t.decimal "price", precision: 19, scale: 10
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "currency"
    t.jsonb "locked_attributes", default: {}
    t.decimal "realized_gain", precision: 19, scale: 4
    t.decimal "cost_basis_amount", precision: 19, scale: 4
    t.string "cost_basis_currency"
    t.integer "holding_period_days"
    t.string "realized_gain_confidence"
    t.string "realized_gain_currency"
    t.string "investment_activity_label"
    t.index ["investment_activity_label"], name: "index_trades_on_investment_activity_label"
    t.index ["realized_gain"], name: "index_trades_on_realized_gain_not_null", where: "(realized_gain IS NOT NULL)"
    t.index ["security_id"], name: "index_trades_on_security_id"
  end

  create_table "transactions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.uuid "category_id"
    t.uuid "merchant_id"
    t.jsonb "locked_attributes", default: {}
    t.string "kind", default: "standard", null: false
    t.string "external_id"
    t.jsonb "extra", default: {}, null: false
    t.string "investment_activity_label"
    t.index ["category_id"], name: "index_transactions_on_category_id"
    t.index ["external_id"], name: "index_transactions_on_external_id"
    t.index ["extra"], name: "index_transactions_on_extra", using: :gin
    t.index ["investment_activity_label"], name: "index_transactions_on_investment_activity_label"
    t.index ["kind"], name: "index_transactions_on_kind"
    t.index ["merchant_id"], name: "index_transactions_on_merchant_id"
  end

  create_table "transfers", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "inflow_transaction_id", null: false
    t.uuid "outflow_transaction_id", null: false
    t.string "status", default: "pending", null: false
    t.text "notes"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["inflow_transaction_id", "outflow_transaction_id"], name: "idx_on_inflow_transaction_id_outflow_transaction_id_8cd07a28bd", unique: true
    t.index ["inflow_transaction_id"], name: "index_transfers_on_inflow_transaction_id"
    t.index ["outflow_transaction_id"], name: "index_transfers_on_outflow_transaction_id"
    t.index ["status"], name: "index_transfers_on_status"
  end

  create_table "users", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "family_id", null: false
    t.string "first_name"
    t.string "last_name"
    t.string "email"
    t.string "password_digest"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "role", default: "member", null: false
    t.boolean "active", default: true, null: false
    t.datetime "onboarded_at"
    t.string "unconfirmed_email"
    t.string "otp_secret"
    t.boolean "otp_required", default: false, null: false
    t.string "otp_backup_codes", default: [], array: true
    t.boolean "show_sidebar", default: true
    t.string "default_period", default: "last_30_days", null: false
    t.uuid "last_viewed_chat_id"
    t.boolean "show_ai_sidebar", default: true
    t.boolean "ai_enabled", default: false, null: false
    t.string "theme", default: "system"
    t.boolean "rule_prompts_disabled", default: false
    t.datetime "rule_prompt_dismissed_at"
    t.text "goals", default: [], array: true
    t.datetime "set_onboarding_preferences_at"
    t.datetime "set_onboarding_goals_at"
    t.string "default_account_order", default: "name_asc"
    t.jsonb "preferences", default: {}, null: false
    t.string "locale"
    t.string "ui_layout"
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["family_id"], name: "index_users_on_family_id"
    t.index ["last_viewed_chat_id"], name: "index_users_on_last_viewed_chat_id"
    t.index ["locale"], name: "index_users_on_locale"
    t.index ["otp_secret"], name: "index_users_on_otp_secret", unique: true, where: "(otp_secret IS NOT NULL)"
    t.index ["preferences"], name: "index_users_on_preferences", using: :gin
  end

  create_table "valuations", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.jsonb "locked_attributes", default: {}
    t.string "kind", default: "reconciliation", null: false
  end

  create_table "vehicles", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "year"
    t.integer "mileage_value"
    t.string "mileage_unit"
    t.string "make"
    t.string "model"
    t.jsonb "locked_attributes", default: {}
    t.string "subtype"
  end

  add_foreign_key "account_providers", "accounts", on_delete: :cascade
  add_foreign_key "accounts", "families"
  add_foreign_key "accounts", "imports"
  add_foreign_key "accounts", "plaid_accounts"
  add_foreign_key "accounts", "simplefin_accounts"
  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "api_keys", "users"
  add_foreign_key "balances", "accounts", on_delete: :cascade
  add_foreign_key "budget_categories", "budgets"
  add_foreign_key "budget_categories", "categories"
  add_foreign_key "budgets", "families"
  add_foreign_key "categories", "families"
  add_foreign_key "chats", "users"
  add_foreign_key "coinbase_accounts", "coinbase_items"
  add_foreign_key "coinbase_items", "families"
  add_foreign_key "coinstats_accounts", "coinstats_items"
  add_foreign_key "coinstats_items", "families"
  add_foreign_key "enable_banking_accounts", "enable_banking_items"
  add_foreign_key "enable_banking_items", "families"
  add_foreign_key "entries", "accounts", on_delete: :cascade
  add_foreign_key "entries", "imports"
  add_foreign_key "eval_results", "eval_runs"
  add_foreign_key "eval_results", "eval_samples"
  add_foreign_key "eval_runs", "eval_datasets"
  add_foreign_key "eval_samples", "eval_datasets"
  add_foreign_key "family_documents", "families"
  add_foreign_key "family_exports", "families"
  add_foreign_key "family_merchant_associations", "families"
  add_foreign_key "family_merchant_associations", "merchants"
  add_foreign_key "holdings", "account_providers"
  add_foreign_key "holdings", "accounts", on_delete: :cascade
  add_foreign_key "holdings", "securities"
  add_foreign_key "holdings", "securities", column: "provider_security_id"
  add_foreign_key "impersonation_session_logs", "impersonation_sessions"
  add_foreign_key "impersonation_sessions", "users", column: "impersonated_id"
  add_foreign_key "impersonation_sessions", "users", column: "impersonator_id"
  add_foreign_key "import_rows", "imports"
  add_foreign_key "imports", "families"
  add_foreign_key "indexa_capital_accounts", "indexa_capital_items"
  add_foreign_key "indexa_capital_items", "families"
  add_foreign_key "invitations", "families"
  add_foreign_key "invitations", "users", column: "inviter_id"
  add_foreign_key "llm_usages", "families"
  add_foreign_key "lunchflow_accounts", "lunchflow_items"
  add_foreign_key "lunchflow_items", "families"
  add_foreign_key "merchants", "families"
  add_foreign_key "mercury_accounts", "mercury_items"
  add_foreign_key "mercury_items", "families"
  add_foreign_key "messages", "chats"
  add_foreign_key "mobile_devices", "users"
  add_foreign_key "oauth_access_grants", "oauth_applications", column: "application_id"
  add_foreign_key "oauth_access_tokens", "oauth_applications", column: "application_id"
  add_foreign_key "oidc_identities", "users"
  add_foreign_key "plaid_accounts", "plaid_items"
  add_foreign_key "plaid_items", "families"
  add_foreign_key "recurring_transactions", "families"
  add_foreign_key "recurring_transactions", "merchants"
  add_foreign_key "rejected_transfers", "transactions", column: "inflow_transaction_id"
  add_foreign_key "rejected_transfers", "transactions", column: "outflow_transaction_id"
  add_foreign_key "rule_actions", "rules"
  add_foreign_key "rule_conditions", "rule_conditions", column: "parent_id"
  add_foreign_key "rule_conditions", "rules"
  add_foreign_key "rule_runs", "rules"
  add_foreign_key "rules", "families"
  add_foreign_key "security_prices", "securities"
  add_foreign_key "sessions", "impersonation_sessions", column: "active_impersonator_session_id"
  add_foreign_key "sessions", "users"
  add_foreign_key "simplefin_accounts", "simplefin_items"
  add_foreign_key "simplefin_items", "families"
  add_foreign_key "snaptrade_accounts", "snaptrade_items"
  add_foreign_key "snaptrade_items", "families"
  add_foreign_key "sso_audit_logs", "users"
  add_foreign_key "subscriptions", "families"
  add_foreign_key "syncs", "syncs", column: "parent_id"
  add_foreign_key "taggings", "tags"
  add_foreign_key "tags", "families"
  add_foreign_key "tool_calls", "messages"
  add_foreign_key "trades", "securities"
  add_foreign_key "transactions", "categories", on_delete: :nullify
  add_foreign_key "transactions", "merchants"
  add_foreign_key "transfers", "transactions", column: "inflow_transaction_id", on_delete: :cascade
  add_foreign_key "transfers", "transactions", column: "outflow_transaction_id", on_delete: :cascade
  add_foreign_key "users", "chats", column: "last_viewed_chat_id"
  add_foreign_key "users", "families"
end
