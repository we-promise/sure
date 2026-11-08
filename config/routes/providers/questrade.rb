resources :questrade_items, only: [ :index, :new, :create, :show, :edit, :update, :destroy ] do
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
