class AddKindToSecurities < ActiveRecord::Migration[7.2]
  def change
    add_column :securities, :kind, :string, null: false, default: "standard"
    add_index :securities, :kind
    add_check_constraint :securities, "kind IN ('standard', 'cash')", name: "chk_securities_kind"
  end
end
