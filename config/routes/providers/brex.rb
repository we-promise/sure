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
