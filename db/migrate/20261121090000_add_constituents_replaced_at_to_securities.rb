class AddConstituentsReplacedAtToSecurities < ActiveRecord::Migration[8.1]
  # When a fund's holdings were last replaced. `constituents_fetched_at` also
  # moves on an answer that replaces nothing, so it cannot tell a concurrent
  # import whether the stored set changed since it read the fund.
  def up
    add_column :securities, :constituents_replaced_at, :datetime
  end

  def down
    remove_column :securities, :constituents_replaced_at
  end
end
