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
