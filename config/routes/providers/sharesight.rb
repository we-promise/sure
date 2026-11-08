resources :sharesight_items, only: [ :create, :update, :destroy ] do
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
