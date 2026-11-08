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
