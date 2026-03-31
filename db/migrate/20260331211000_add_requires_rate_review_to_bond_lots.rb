class AddRequiresRateReviewToBondLots < ActiveRecord::Migration[7.2]
  def change
    add_column :bond_lots, :requires_rate_review, :boolean, default: false, null: false

    add_index :bond_lots, :requires_rate_review
  end
end
