class AddConstituentsReplacedAtToSecurities < ActiveRecord::Migration[8.1]
  # When a fund's holdings were last replaced. `constituents_fetched_at` also
  # moves on an answer that replaces nothing, so it cannot tell a concurrent
  # import whether the stored set changed since it read the fund.
  def up
    add_column :securities, :constituents_replaced_at, :datetime

    # A fund with stored holdings had them replaced when it was last stamped.
    execute <<~SQL
      UPDATE securities SET constituents_replaced_at = constituents_fetched_at
      WHERE EXISTS (SELECT 1 FROM security_constituents WHERE security_constituents.security_id = securities.id)
    SQL
  end

  def down
    remove_column :securities, :constituents_replaced_at
  end
end
