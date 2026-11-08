resources :wise_items, only: %i[index new create show edit update destroy] do
  collection do
    get :select_profiles
    post :link_profiles
    get :select_accounts
    post :link_accounts
    get :select_existing_account
    post :link_existing_account
  end

  member do
    post :sync
    get :setup_accounts
    post :complete_account_setup
    post :generate_sca_keypair
  end
end
