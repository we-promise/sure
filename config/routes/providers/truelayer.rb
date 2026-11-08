resources :truelayer_items, only: [ :create, :update, :destroy ] do
  collection do
    get :callback
    post :connect
    get :select_existing_account
    post :link_existing_account
  end
  member do
    post :sync
    post :reauthorize
    get :setup_accounts
    post :complete_account_setup
  end
end
