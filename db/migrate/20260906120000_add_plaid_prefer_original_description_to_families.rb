class AddPlaidPreferOriginalDescriptionToFamilies < ActiveRecord::Migration[7.2]
  # Opt-in, per family: name Plaid transactions with the bank's raw description
  # instead of Plaid's cleaned-up merchant name. Defaults off so existing
  # installs keep the naming they have.
  #
  # @return [void]
  def change
    add_column :families, :plaid_prefer_original_description, :boolean, default: false, null: false
  end
end
