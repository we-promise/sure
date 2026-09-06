class AddOverdraftTermsToDepositories < ActiveRecord::Migration[7.2]
  def change
    # `depositories` carried nothing but subtype and locked_attributes, so a
    # checking account's most consequential numbers, the point at which it goes
    # into unauthorized overdraft and what the bank charges for it, existed
    # nowhere in Sure. An assistant reading the data could only advise "never go
    # below zero", which is both wrong and needlessly alarming for a holder with
    # an agreed facility.
    #
    # Stored POSITIVE. A limit of 400 means the balance may fall to -400. The
    # sign convention is asserted in Depository so no caller has to guess.
    add_column :depositories, :overdraft_limit, :decimal, precision: 19, scale: 4

    # Annual rate charged on the debit balance (agios). Same precision as
    # loans.interest_rate so the two are directly comparable.
    add_column :depositories, :overdraft_interest_rate, :decimal, precision: 10, scale: 3

    # Per-payment penalty, charged when a payment that pushes the account past
    # its limit is larger than `intervention_fee_threshold`. Both nullable: a
    # bank with no such fee simply leaves them unset, which reads as "unknown"
    # rather than as zero.
    add_column :depositories, :intervention_fee_amount, :decimal, precision: 19, scale: 4
    add_column :depositories, :intervention_fee_threshold, :decimal, precision: 19, scale: 4

    # Banks cap these fees either by money or by count, and some do both, so
    # both forms exist and either may be left null.
    add_column :depositories, :intervention_fee_monthly_cap, :decimal, precision: 19, scale: 4
    add_column :depositories, :intervention_fee_monthly_count_cap, :integer

    # A negative limit or fee is always a data-entry error, never a real
    # product, and it would silently invert every projection built on it.
    add_check_constraint :depositories,
                         "overdraft_limit IS NULL OR overdraft_limit >= 0",
                         name: "chk_depositories_overdraft_limit_non_negative"
    add_check_constraint :depositories,
                         "intervention_fee_amount IS NULL OR intervention_fee_amount >= 0",
                         name: "chk_depositories_intervention_fee_non_negative"
    add_check_constraint :depositories,
                         "intervention_fee_monthly_count_cap IS NULL OR intervention_fee_monthly_count_cap >= 0",
                         name: "chk_depositories_intervention_count_cap_non_negative"

    # The remaining terms are optional too, so each stays nullable, but a
    # negative agios rate, threshold or cap is the same data-entry error and
    # would invert the same projections.
    add_check_constraint :depositories,
                         "overdraft_interest_rate IS NULL OR overdraft_interest_rate >= 0",
                         name: "chk_depositories_overdraft_rate_non_negative"
    add_check_constraint :depositories,
                         "intervention_fee_threshold IS NULL OR intervention_fee_threshold >= 0",
                         name: "chk_depositories_intervention_threshold_non_negative"
    add_check_constraint :depositories,
                         "intervention_fee_monthly_cap IS NULL OR intervention_fee_monthly_cap >= 0",
                         name: "chk_depositories_intervention_monthly_cap_non_negative"
  end
end
