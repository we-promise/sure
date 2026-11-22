class AddMatchKindsAppliedToTransfers < ActiveRecord::Migration[8.1]
  def change
    add_column :transfers, :match_kinds_applied, :boolean, default: false, null: false
  end
end
