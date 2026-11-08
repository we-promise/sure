# CoinStats routes
resources :coinstats_items, only: [ :index, :new, :create, :update, :destroy ] do
  collection do
    post :link_wallet
    post :link_exchange
  end
  member do
    post :sync
  end
end
