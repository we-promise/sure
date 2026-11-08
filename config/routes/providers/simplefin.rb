resources :simplefin_items, only: %i[index new create show edit update destroy] do
  collection do
    get :select_existing_account
    post :link_existing_account
  end

  member do
    post :sync
    post :balances
    get :setup_accounts
    post :complete_account_setup
    post :dismiss_replacement_suggestion
  end
end
