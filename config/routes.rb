require "sidekiq/web"
require "sidekiq/cron/web"

Rails.application.routes.draw do
  resources :indexa_capital_items, only: [ :index, :new, :create, :show, :edit, :update, :destroy ] do
    collection do
      get :preload_accounts
      get :select_accounts
      post :link_accounts
      get :select_existing_account
      post :link_existing_account
    end

    member do
      post :sync
      get :setup_accounts
      post :complete_account_setup
    end
  end
  resources :mercury_items, only: %i[index new create show edit update destroy] do
    collection do
      get :preload_accounts
      get :select_accounts
      post :link_accounts
      get :select_existing_account
      post :link_existing_account
    end

    member do
      post :sync
      get :setup_accounts
      post :complete_account_setup
    end
  end

  resources :brex_items, only: %i[index new create show edit update destroy] do
    collection do
      get :preload_accounts, to: "brex_items/account_flows#preload_accounts"
      get :select_accounts, to: "brex_items/account_flows#select_accounts"
      post :link_accounts, to: "brex_items/account_flows#link_accounts"
      get :select_existing_account, to: "brex_items/account_flows#select_existing_account"
      post :link_existing_account, to: "brex_items/account_flows#link_existing_account"
    end

    member do
      post :sync
      get :setup_accounts, to: "brex_items/account_setups#setup_accounts"
      post :complete_account_setup, to: "brex_items/account_setups#complete_account_setup"
    end
  end

  resources :coinbase_items, only: [ :index, :new, :create, :show, :edit, :update, :destroy ] do
    collection do
      get :preload_accounts
      get :select_accounts
      post :link_accounts
      get :select_existing_account
      post :link_existing_account
    end

    member do
      post :sync
      get :setup_accounts
      post :complete_account_setup
    end
  end

  resources :binance_items, only: [ :index, :new, :create, :show, :edit, :update, :destroy ] do
    collection do
      get :select_accounts
      post :link_accounts
      get :select_existing_account
      post :link_existing_account
    end

    member do
      post :sync
      get :setup_accounts
      post :complete_account_setup
    end
  end

  resources :kraken_items, only: [ :create, :update, :destroy ] do
    collection do
      get :select_accounts
      post :link_accounts
      get :select_existing_account
      post :link_existing_account
    end

    member do
      post :sync
      get :setup_accounts
      post :complete_account_setup
    end
  end

  resources :snaptrade_items, only: [ :index, :new, :create, :show, :edit, :update, :destroy ] do
    collection do
      get :preload_accounts
      get :select_accounts
      post :link_accounts
      get :select_existing_account
      post :link_existing_account
      get :callback
    end

    member do
      post :sync
      get :connect
      get :setup_accounts
      post :complete_account_setup
      get :connections
      delete :delete_connection
      delete :delete_orphaned_user
    end
  end

  resources :ibkr_items, only: [ :create, :update, :destroy ] do
    collection do
      get :select_accounts
      get :select_existing_account
      post :link_existing_account
    end

    member do
      post :sync
      get :setup_accounts
      post :complete_account_setup
    end
  end

  # CoinStats routes
  resources :coinstats_items, only: [ :index, :new, :create, :update, :destroy ] do
    collection do
      post :link_wallet
      post :link_exchange
    end
    member do
      post :sync
    end
  end

  resources :enable_banking_items, only: [ :new, :create, :update, :destroy ] do
    collection do
      get :callback
      post :link_accounts
      get :select_existing_account
      post :link_existing_account
    end
    member do
      post :sync
      get :select_bank
      post :authorize
      post :reauthorize
      get :setup_accounts
      post :complete_account_setup
      post :new_connection
    end
  end
  use_doorkeeper
  # MFA routes
  resource :mfa, controller: "mfa", only: [ :new, :create ] do
    get :verify
    post :verify, to: "mfa#verify_code"
    post :webauthn_options
    post :verify_webauthn
    delete :disable
  end

  mount Lookbook::Engine, at: "/design-system"

  if Rails.env.development?
    mount Rswag::Api::Engine => "/api-docs"
    mount Rswag::Ui::Engine => "/api-docs"
  end

  # Uses basic auth - see config/initializers/sidekiq.rb
  mount Sidekiq::Web => "/sidekiq"

  # AI chats
  resources :chats do
    resources :messages, only: :create

    member do
      post :retry
    end
  end

  resources :family_exports, only: %i[new create index destroy] do
    member do
      get :download
    end
  end

  get "exports/archive/:token", to: "archived_exports#show", as: :archived_export

  get "changelog", to: "pages#changelog"
  get "feedback", to: "pages#feedback"
  patch "dashboard/preferences", to: "pages#update_preferences"

  resource :current_session, only: %i[update]

  resource :registration, only: %i[new create]
  resources :sessions, only: %i[index new create destroy]
  get "/auth/mobile/:provider", to: "sessions#mobile_sso_start"
  match "/auth/:provider/callback", to: "sessions#openid_connect", via: %i[get post]
  match "/auth/failure", to: "sessions#failure", via: %i[get post]
  get "/auth/logout/callback", to: "sessions#post_logout"
  resource :oidc_account, only: [] do
    get :link, on: :collection
    post :create_link, on: :collection
    get :new_user, on: :collection
    post :create_user, on: :collection
  end
  resource :password_reset, only: %i[new create edit update]
  resource :password, only: %i[edit update]
  resource :email_confirmation, only: :new

  resources :users, only: %i[update destroy] do
    delete :reset, on: :member
    delete :reset_with_sample_data, on: :member
    patch :rule_prompt_settings, on: :member
    get :resend_confirmation_email, on: :member
  end

  resource :onboarding, only: :show do
    collection do
      get :preferences
      get :goals
      get :trial
    end
  end

  namespace :settings do
    resource :profile, only: [ :show, :destroy ]
    resource :preferences, only: :show
    resource :appearance, only: %i[show update]
    resource :hosting, only: %i[show update] do
      delete :clear_cache, on: :collection
      delete :disconnect_external_assistant, on: :collection
    end
    resource :payment, only: :show
    resource :security, only: :show
    resources :webauthn_credentials, only: %i[create destroy] do
      post :options, on: :collection
    end
    resources :sso_identities, only: :destroy
    resource :api_key, only: [ :show, :new, :create, :destroy ]
    resource :ai_prompts, only: :show
    resource :llm_usage, only: :show
    resource :guides, only: :show
    get "bank_sync", to: redirect("/settings/providers", status: 301)
    resource :providers, only: %i[show update] do
      collection do
        post :sync_all
        post ":provider_key/sync", action: :sync, as: :sync_provider
        get ":provider_key/connect_form", action: :connect_form, as: :connect_form
      end
    end
  end

  resource :subscription, only: %i[new show create] do
    collection do
      get :upgrade
      get :success
    end
  end

  resources :tags, except: :show do
    resources :deletions, only: %i[new create], module: :tag
    delete :destroy_all, on: :collection
  end

  namespace :category do
    resource :dropdown, only: :show
  end

  resources :categories, except: :show do
    resources :deletions, only: %i[new create], module: :category

    post :bootstrap, on: :collection
    delete :destroy_all, on: :collection
  end

  resources :reports, only: %i[index] do
    patch :update_preferences, on: :collection
    get :export_transactions, on: :collection
    get :google_sheets_instructions, on: :collection
    get :print, on: :collection
    get :picker, on: :collection
  end

  resources :budgets, only: %i[index show edit update], param: :month_year do
    post :copy_previous, on: :member
    get :picker, on: :collection

    resources :budget_categories, only: %i[index show update]
  end

  resources :family_merchants, only: %i[index new create edit update destroy] do
    collection do
      get :merge
      post :perform_merge
      post :enhance
    end
  end

  get :exchange_rate, to: "exchange_rates#show"

  resources :transfers, only: %i[new create destroy show update] do
    member do
      post :mark_as_recurring
    end
  end

  resources :imports, only: %i[index new show create update destroy] do
    member do
      post :publish
      put :revert
      put :apply_template
    end

    resource :upload, only: %i[show update], module: :import
    resource :configuration, only: %i[show update], module: :import
    resource :clean, only: :show, module: :import
    resource :confirm, only: :show, module: :import
    resource :qif_category_selection, only: %i[show update], module: :import

    resources :rows, only: %i[show update], module: :import
    resources :mappings, only: :update, module: :import
  end

  resources :holdings, only: %i[index new show update destroy] do
    member do
      post :unlock_cost_basis
      patch :remap_security
      post :reset_security
      post :sync_prices
    end
  end
  resources :trades, only: %i[show new create update destroy] do
    member do
      post :unlock
    end
  end
  resources :valuations, only: %i[show new create update destroy] do
    post :confirm_create, on: :collection
    post :confirm_update, on: :member
  end

  namespace :transactions do
    resource :bulk_deletion, only: :create
    resource :bulk_update, only: %i[new create]
    resource :categorize, only: %i[show create] do
      patch :assign_entry, on: :collection
      get :preview_rule, on: :collection
    end
  end

  resources :transactions, only: %i[index new create show update destroy] do
    resource :split, only: %i[new create edit update destroy]
    resource :transfer_match, only: %i[new create]
    resource :pending_duplicate_merges, only: %i[new create]
    resource :category, only: :update, controller: :transaction_categories
    resources :attachments, only: %i[show create destroy], controller: :transaction_attachments

    collection do
      delete :clear_filter
      patch :update_preferences
    end

    member do
      get :convert_to_trade
      post :create_trade_from_transaction
      post :mark_as_recurring
      post :merge_duplicate
      post :dismiss_duplicate
      post :unlock
    end
  end

  resources :recurring_transactions, only: %i[index destroy] do
    collection do
      match :identify, via: [ :get, :post ]
      match :cleanup, via: [ :get, :post ]
      patch :update_settings
    end

    member do
      match :toggle_status, via: [ :get, :post ]
    end
  end

  resources :accountable_sparklines, only: :show, param: :accountable_type

  direct :entry do |entry, options|
    if entry.new_record?
      route_for entry.entryable_name.pluralize, options
    else
      route_for entry.entryable_name, entry, options
    end
  end

  resources :rules, except: :show do
    member do
      get :confirm
      post :apply
    end

    collection do
      delete :destroy_all
      get :confirm_all
      post :apply_all
      post :clear_ai_cache
    end
  end

  resources :accounts, only: %i[index new show destroy], shallow: true do
    member do
      post :sync
      get :sparkline
      patch :toggle_active
      patch :set_default
      patch :remove_default
      get :select_provider
      get :confirm_unlink
      delete :unlink
    end

    collection do
      post :sync_all
    end

    resource :sharing, only: [ :show, :update ], controller: "account_sharings"
  end

  resources :account_statements, only: %i[index show create update destroy] do
    member do
      patch :link
      patch :unlink
      patch :reject
    end
  end

  # Convenience routes for polymorphic paths
  # Example: account_path(Account.new(accountable: Depository.new)) => /depositories/123
  direct :edit_account do |model, options|
    route_for "edit_#{model.accountable_name}", model, options
  end

  resources :depositories, only: %i[new create edit update]
  resources :investments, only: %i[new create edit update]
  resources :properties, only: %i[new create edit update] do
    member do
      get :balances
      patch :update_balances

      get :address
      patch :update_address
    end
  end
  resources :vehicles, only: %i[new create edit update]
  resources :credit_cards, only: %i[new create edit update]
  resources :loans, only: %i[new create edit update]
  resources :cryptos, only: %i[new create edit update]
  resources :other_assets, only: %i[new create edit update]
  resources :other_liabilities, only: %i[new create edit update]

  resources :securities, only: :index

  resources :invite_codes, only: %i[index create destroy]

  resources :invitations, only: [ :new, :create, :destroy ] do
    get :accept, on: :member
  end

  # API routes
  namespace :api do
    namespace :v1 do
      # Authentication endpoints
      post "auth/signup", to: "auth#signup"
      post "auth/login", to: "auth#login"
      post "auth/refresh", to: "auth#refresh"
      post "auth/sso_exchange", to: "auth#sso_exchange"
      post "auth/sso_link", to: "auth#sso_link"
      post "auth/sso_create_account", to: "auth#sso_create_account"
      patch "auth/enable_ai", to: "auth#enable_ai"

      # Production API endpoints
      resources :accounts, only: [ :index, :show ]
      resources :balances, only: [ :index, :show ]
      resources :budgets, only: [ :index, :show ]
      resources :budget_categories, only: [ :index, :show ]
      resources :categories, only: [ :index, :show, :create ]
      resources :merchants, only: [ :index, :show ]
      resources :rules, only: [ :index, :show ]
      resources :rule_runs, only: [ :index, :show ]
      resources :securities, only: [ :index, :show ]
      resources :security_prices, only: [ :index, :show ]
      resources :tags, only: [ :index, :show, :create, :update, :destroy ]

      resources :transactions, only: [ :index, :show, :create, :update, :destroy ]
      resources :trades, only: [ :index, :show, :create, :update, :destroy ]
      resources :holdings, only: [ :index, :show ]
      resources :transfers, only: [ :index, :show ]
      resources :rejected_transfers, only: [ :index, :show ]
      resources :valuations, only: [ :index, :create, :update, :show ]
      resources :recurring_transactions, only: [ :index, :show, :create, :update, :destroy ]
      resources :family_exports, only: [ :index, :show, :create ] do
        get :download, on: :member
      end
      resources :imports, only: [ :index, :show, :create ] do
        post :preflight, on: :collection
        get :rows, on: :member
      end
      resource :usage, only: [ :show ], controller: :usage
      resource :balance_sheet, only: [ :show ], controller: :balance_sheet
      resource :family_settings, only: [ :show ], controller: :family_settings
      post :sync, to: "sync#create", as: :sync_job
      resources :syncs, only: [ :index, :show ] do
        get :latest, on: :collection
      end
      resources :provider_connections, only: [ :index ]

      resources :chats, only: [ :index, :show, :create, :update, :destroy ] do
        resources :messages, only: [ :create ] do
          post :retry, on: :collection
        end
      end

      get "users/reset/status", to: "users#reset_status"
      delete "users/reset", to: "users#reset"
      delete "users/me", to: "users#destroy"

      # Test routes for API controller testing (only available in test environment)
      if Rails.env.test?
        get "test", to: "test#index"
        get "test_not_found", to: "test#not_found"
        get "test_family_access", to: "test#family_access"
        get "test_scope_required", to: "test#scope_required"
        get "test_multiple_scopes_required", to: "test#multiple_scopes_required"
      end
    end
  end



  resources :currencies, only: %i[show]

  resources :impersonation_sessions, only: [ :create ] do
    post :join, on: :collection
    delete :leave, on: :collection

    member do
      put :approve
      put :reject
      put :complete
    end
  end

  resources :plaid_items, only: %i[new edit create destroy] do
    collection do
      get :select_existing_account
      post :link_existing_account
    end

    member do
      post :sync
    end
  end

  resources :simplefin_items, only: %i[index new create show edit update destroy] do
    collection do
      get :select_existing_account
      post :link_existing_account
    end

    member do
      post :sync
      post :balances
      get :setup_accounts
      post :complete_account_setup
      post :dismiss_replacement_suggestion
    end
  end

  resources :lunchflow_items, only: %i[index new create show edit update destroy] do
    collection do
      get :preload_accounts
      get :select_accounts
      post :link_accounts
      get :select_existing_account
      post :link_existing_account
    end

    member do
      post :sync
      get :setup_accounts
      post :complete_account_setup
    end
  end

  resources :sophtron_items, only: %i[index new create show edit update destroy] do
    collection do
      get :preload_accounts
      get :select_accounts
      post :link_accounts
      get :select_existing_account
      post :link_existing_account
    end

    member do
      post :connect_institution
      post :sync
      post :toggle_manual_sync
      post :balances
      get :connection_status
      post :submit_mfa
      get :setup_accounts
      post :complete_account_setup
    end
  end

  namespace :webhooks do
    post "plaid"
    post "plaid_eu"
    post "stripe"
  end

  get "redis-configuration-error", to: "pages#redis_configuration_error"

  # MCP server endpoint for external AI assistants (JSON-RPC 2.0)
  post "mcp", to: "mcp#handle"

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/*
  get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker
  get "manifest" => "rails/pwa#manifest", as: :pwa_manifest

  get "imports/:import_id/upload/sample_csv", to: "import/uploads#sample_csv", as: :import_upload_sample_csv

  privacy_url = ENV["LEGAL_PRIVACY_URL"].presence
  terms_url = ENV["LEGAL_TERMS_URL"].presence
  get "privacy", to: privacy_url ? redirect(privacy_url) : "pages#privacy"
  get "terms", to: terms_url ? redirect(terms_url) : "pages#terms"
  get "intro", to: "pages#intro"

  # Admin namespace for super admin functionality
  namespace :admin do
    resources :sso_providers do
      member do
        patch :toggle
        post :test_connection
      end
    end
    resources :users, only: [ :index, :update ]
    resources :invitations, only: [ :destroy ]
    resources :families, only: [] do
      member do
        delete :invitations, to: "invitations#destroy_all"
      end
    end
  end

  # Defines the root path route ("/")
  root "pages#dashboard"
end
