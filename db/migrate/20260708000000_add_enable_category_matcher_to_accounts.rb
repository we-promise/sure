class AddEnableCategoryMatcherToAccounts < ActiveRecord::Migration[7.2]
  def change
    add_column :accounts, :enable_category_matcher, :boolean, default: true, null: false
  end
end
