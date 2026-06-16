class AddKindToTransfers < ActiveRecord::Migration[7.2]
  def change
    add_column :transfers, :kind, :string, default: "standard", null: false
  end
end
