# Self-custody / on-chain wallets
resources :onchain_wallet_items, only: [ :update, :destroy ] do
  collection do
    get :new_wallet
    post :preview_wallet
    post :link_wallet
    post :enable_crypto_prices
  end

  member do
    post :sync
    get :manage
    get :review_tokens
    post :update_tokens
    delete :disconnect_wallet
    delete :disconnect_asset
  end
end
