class AddCategorizationProviderToFamilies < ActiveRecord::Migration[8.1]
  def change
    add_column :families, :categorization_provider, :string, default: "llm", null: false

    # Matches chk_families_default_account_sharing on this table: the model
    # validation does not bind update_column or a data migration, and a garbage
    # value here silently changes which provider sees a family's transactions.
    add_check_constraint :families,
                         "categorization_provider::text = ANY (ARRAY['llm'::character varying::text, 'jev'::character varying::text])",
                         name: "chk_families_categorization_provider"
  end
end
