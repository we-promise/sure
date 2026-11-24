class BackfillMaterializedHoldings < ActiveRecord::Migration[8.1]
  # Keep this version for databases that ran the draft. The companion
  # balance timestamps cannot establish who last wrote the holding.
  def up
  end

  def down
  end
end
