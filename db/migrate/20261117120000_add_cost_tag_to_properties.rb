class AddCostTagToProperties < ActiveRecord::Migration[8.1]
  def change
    # The tag that marks a property's purchase costs (notary fees, taxes,
    # registration). Deleting the tag clears the link, not the property.
    add_reference :properties, :cost_tag, type: :uuid, null: true, index: true,
                  foreign_key: { to_table: :tags, on_delete: :nullify }
  end
end
