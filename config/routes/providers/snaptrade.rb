resources :snaptrade_items, only: [ :index, :show, :destroy ] do
  collection do
    get :preload_accounts
    get :select_accounts
    get :select_existing_account
    post :link_existing_account
    get :callback
    get :oauth_authorize
    get :oauth_callback
    get :oauth_device_authorize
    post :start_oauth_device_flow
  end

  member do
    post :sync
    get :connect
    get :setup_accounts
    post :complete_account_setup
    get :connections
    post :complete_oauth_device_flow
    delete :delete_connection
  end
end
