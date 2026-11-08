resources :plaid_items, only: %i[new edit create destroy] do
  collection do
    get :select_existing_account
    post :link_existing_account
  end

  member do
    post :sync
  end
end
