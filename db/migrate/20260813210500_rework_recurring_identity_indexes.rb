class ReworkRecurringIdentityIndexes < ActiveRecord::Migration[7.2]
  # The four identity indexes included `amount`, so any price change forked the
  # series into a second row instead of updating the first -- auto-detection is
  # amount-scoped by construction. Identity becomes
  # (family, account, [destination], merchant|name, currency, dedup_scope):
  # price changes update `amount` freely, and the rare LEGITIMATE second series
  # for one identifier (three Twitch tiers) carries a discriminator in
  # dedup_scope instead.
  def up
    add_column :recurring_transactions, :dedup_scope, :string, null: false, default: ""

    stamp_existing_price_forks

    remove_index :recurring_transactions, name: "idx_recurring_txns_acct_merchant"
    remove_index :recurring_transactions, name: "idx_recurring_txns_acct_name"
    remove_index :recurring_transactions, name: "idx_recurring_txns_pair_merchant"
    remove_index :recurring_transactions, name: "idx_recurring_txns_pair_name"

    add_index :recurring_transactions,
              [ :family_id, :account_id, :merchant_id, :currency, :dedup_scope ],
              unique: true, name: "idx_recurring_txns_acct_merchant",
              where: "merchant_id IS NOT NULL AND destination_account_id IS NULL"
    add_index :recurring_transactions,
              [ :family_id, :account_id, :name, :currency, :dedup_scope ],
              unique: true, name: "idx_recurring_txns_acct_name",
              where: "name IS NOT NULL AND merchant_id IS NULL AND destination_account_id IS NULL"
    add_index :recurring_transactions,
              [ :family_id, :account_id, :destination_account_id, :merchant_id, :currency, :dedup_scope ],
              unique: true, name: "idx_recurring_txns_pair_merchant",
              where: "destination_account_id IS NOT NULL AND merchant_id IS NOT NULL"
    add_index :recurring_transactions,
              [ :family_id, :account_id, :destination_account_id, :name, :currency, :dedup_scope ],
              unique: true, name: "idx_recurring_txns_pair_name",
              where: "destination_account_id IS NOT NULL AND name IS NOT NULL AND merchant_id IS NULL"
  end

  def down
    remove_index :recurring_transactions, name: "idx_recurring_txns_acct_merchant"
    remove_index :recurring_transactions, name: "idx_recurring_txns_acct_name"
    remove_index :recurring_transactions, name: "idx_recurring_txns_pair_merchant"
    remove_index :recurring_transactions, name: "idx_recurring_txns_pair_name"

    add_index :recurring_transactions,
              [ :family_id, :account_id, :merchant_id, :amount, :currency ],
              unique: true, name: "idx_recurring_txns_acct_merchant",
              where: "merchant_id IS NOT NULL AND destination_account_id IS NULL"
    add_index :recurring_transactions,
              [ :family_id, :account_id, :name, :amount, :currency ],
              unique: true, name: "idx_recurring_txns_acct_name",
              where: "name IS NOT NULL AND merchant_id IS NULL AND destination_account_id IS NULL"
    add_index :recurring_transactions,
              [ :family_id, :account_id, :destination_account_id, :merchant_id, :amount, :currency ],
              unique: true, name: "idx_recurring_txns_pair_merchant",
              where: "destination_account_id IS NOT NULL AND merchant_id IS NOT NULL"
    add_index :recurring_transactions,
              [ :family_id, :account_id, :destination_account_id, :name, :amount, :currency ],
              unique: true, name: "idx_recurring_txns_pair_name",
              where: "destination_account_id IS NOT NULL AND name IS NOT NULL AND merchant_id IS NULL"

    remove_column :recurring_transactions, :dedup_scope
  end

  private
    # Rows that collide once amount leaves the identity are either price-change
    # forks or genuinely distinct series for one identifier. The migration
    # cannot tell them apart, so it keeps the newest row unscoped and stamps
    # the rest with their amount as a discriminator -- preserving every row and
    # the old identity semantics exactly -- and logs each group for a one-time
    # human review.
    def stamp_existing_price_forks
      rows = select_all(<<~SQL).to_a
        SELECT id, family_id, account_id, destination_account_id, merchant_id, name, currency,
               amount, updated_at
        FROM recurring_transactions
        ORDER BY updated_at DESC
      SQL

      groups = rows.group_by do |row|
        [ row["family_id"], row["account_id"], row["destination_account_id"],
          row["merchant_id"] || "name:#{row['name']}", row["currency"] ]
      end

      groups.each_value do |group|
        next if group.size == 1

        keeper, *rest = group
        say "dedup_scope: keeping #{keeper['id']} (#{keeper['amount']}) unscoped; stamping #{rest.size} sibling(s)"

        rest.each do |row|
          scope = BigDecimal(row["amount"].to_s).to_s("F")
          say "  #{row['id']} amount=#{row['amount']} -> dedup_scope=#{scope}"
          update("UPDATE recurring_transactions SET dedup_scope = #{quote(scope)} WHERE id = #{quote(row['id'])}")
        end
      end
    end
end
