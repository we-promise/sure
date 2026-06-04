class AddFillDirectionToPockets < ActiveRecord::Migration[7.2]
  def change
    add_column :pockets, :fill_direction, :string, null: false, default: "inflows"
    add_check_constraint :pockets,
      "fill_direction IN ('inflows', 'outflows', 'both')",
      name: "chk_pockets_fill_direction"
  end
end
