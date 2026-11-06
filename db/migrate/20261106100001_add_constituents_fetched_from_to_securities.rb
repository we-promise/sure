class AddConstituentsFetchedFromToSecurities < ActiveRecord::Migration[8.1]
  # The provider key that answered when `constituents_fetched_at` was
  # stamped. A different provider has not been asked.
  def change
    add_column :securities, :constituents_fetched_from, :string
  end
end
