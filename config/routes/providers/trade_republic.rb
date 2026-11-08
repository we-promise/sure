# Trade Republic routes (login steps are TR-specific: web login needs a
# two-phase initiate/confirm handshake with the Trade Republic app)
resources :trade_republic_items, only: [ :show, :create, :update, :destroy ] do
  collection do
    get :select_accounts
    get :select_existing_account
    post :link_existing_account
  end

  member do
    post :sync
    post :repair
    get :setup_accounts
    post :complete_account_setup
    post :initiate_login
    post :complete_login
    post :poll_login
    post :initiate_qr_login
    post :poll_qr_login
    post :cancel_qr_login
  end
end
