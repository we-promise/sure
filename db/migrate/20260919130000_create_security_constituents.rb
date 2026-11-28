class CreateSecurityConstituents < ActiveRecord::Migration[8.1]
  def change
    create_table :security_constituents, id: :uuid do |t|
      t.references :security, null: false, foreign_key: true, type: :uuid

      # Stored as text rather than as a reference to `securities`. Resolving
      # every constituent into that table would create hundreds of rows per fund
      # for instruments nobody holds, and the look-through only needs the weight
      # and something to label it with.
      t.string :ticker, null: false
      t.string :name

      # The provider's own figure, as a percentage of fund assets. Not
      # normalised on the way in: a fund's holdings routinely sum to something
      # other than 100 (cash, rounding, securities lending), and that sum is
      # information the reader of the row should still be able to see.
      t.decimal :weight, precision: 9, scale: 6

      t.timestamps
    end

    add_index :security_constituents, [ :security_id, :ticker ], unique: true

    # Written whether or not the provider returned anything, so the skip gate can
    # tell "never asked" from "asked, nothing came back". Keyed on the presence
    # of constituents instead, a fund the provider has no holdings for would be
    # re-asked on every sync, for ever.
    add_column :securities, :constituents_fetched_at, :datetime
  end
end
