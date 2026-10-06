# frozen_string_literal: true

# Account availability ("liquidity"): how quickly the money in an account can be
# reached, plus an optional release date for money that is locked until a date.
#
# The backfill classifies every existing account from its type and subtype with
# a frozen snapshot of the defaults in Account::Liquidity / Accountable. It is a
# snapshot on purpose: later changes to the defaults must not rewrite what this
# migration did. The DB default stays 'immediate' so code paths that insert
# accounts without going through the model keep working.
class AddLiquidityToAccounts < ActiveRecord::Migration[8.1]
  LEVELS = %w[immediate short_term locked long_term].freeze

  INVESTMENT_LOCKED_SUBTYPES = %w[fd rd nsc kvp].freeze

  # Investment subtypes whose tax treatment is not :taxable at the time of
  # writing (tax_deferred, tax_exempt, tax_advantaged).
  INVESTMENT_LONG_TERM_SUBTYPES = %w[
    401k roth_401k 403b 457b tsp ira roth_ira sep_ira simple_ira 529_plan hsa
    isa lisa sipp workplace_pension_uk tfsa rrsp fhsa rdsp resp dpsp prpp lira
    rrif lif lrif prif rlif super smsf assurance_vie pea pillar_3a riester nps
    apy life_insurance ppf ssy infrastructure_bond tax_free_bond sgb pension
    retirement
  ].freeze

  def up
    add_column :accounts, :liquidity, :string, null: false, default: "immediate"
    add_column :accounts, :available_on, :date
    add_column :accounts, :auto_renew, :boolean, null: false, default: false
    add_column :accounts, :renewal_term_months, :integer

    add_check_constraint :accounts, "liquidity IN ('immediate', 'short_term', 'locked', 'long_term')",
                         name: "chk_accounts_liquidity"
    add_check_constraint :accounts, "renewal_term_months IS NULL OR renewal_term_months > 0",
                         name: "chk_accounts_renewal_term_months"

    add_index :accounts, [ :family_id, :liquidity ]

    backfill_liquidity
  end

  def down
    remove_index :accounts, [ :family_id, :liquidity ]
    remove_check_constraint :accounts, name: "chk_accounts_renewal_term_months"
    remove_check_constraint :accounts, name: "chk_accounts_liquidity"
    remove_column :accounts, :renewal_term_months
    remove_column :accounts, :auto_renew
    remove_column :accounts, :available_on
    remove_column :accounts, :liquidity
  end

  private
    def backfill_liquidity
      execute <<~SQL.squish
        UPDATE accounts SET liquidity = 'locked'
        FROM depositories
        WHERE accounts.accountable_type = 'Depository' AND depositories.id = accounts.accountable_id
          AND depositories.subtype = 'cd'
      SQL

      execute <<~SQL.squish
        UPDATE accounts SET liquidity = 'short_term'
        FROM depositories
        WHERE accounts.accountable_type = 'Depository' AND depositories.id = accounts.accountable_id
          AND depositories.subtype = 'money_market'
      SQL

      execute <<~SQL.squish
        UPDATE accounts SET liquidity = 'long_term'
        FROM depositories
        WHERE accounts.accountable_type = 'Depository' AND depositories.id = accounts.accountable_id
          AND depositories.subtype = 'hsa'
      SQL

      execute <<~SQL.squish
        UPDATE accounts SET liquidity = CASE
          WHEN investments.subtype IN (#{quoted(INVESTMENT_LOCKED_SUBTYPES)}) THEN 'locked'
          WHEN investments.subtype IN (#{quoted(INVESTMENT_LONG_TERM_SUBTYPES)}) THEN 'long_term'
          ELSE 'short_term'
        END
        FROM investments
        WHERE accounts.accountable_type = 'Investment' AND investments.id = accounts.accountable_id
      SQL

      execute <<~SQL.squish
        UPDATE accounts SET liquidity = 'short_term' WHERE accountable_type = 'Crypto'
      SQL

      execute <<~SQL.squish
        UPDATE accounts SET liquidity = 'long_term'
        WHERE accountable_type IN ('Property', 'Vehicle', 'OtherAsset', 'OtherLiability')
      SQL

      execute <<~SQL.squish
        UPDATE accounts SET liquidity = CASE WHEN loans.subtype = 'line_of_credit' THEN 'immediate' ELSE 'long_term' END
        FROM loans
        WHERE accounts.accountable_type = 'Loan' AND loans.id = accounts.accountable_id
      SQL
    end

    def quoted(values)
      values.map { |value| connection.quote(value) }.join(", ")
    end
end
