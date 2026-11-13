class AddCategorizationConfidenceControlsToFamilies < ActiveRecord::Migration[8.1]
  def change
    # 0.7 is where the confidence signal stops paying. Measured over the
    # 200-sample categorization golden set: withholding below 0.7 leaves 91.5% of
    # transactions categorized and takes the error rate on what IS applied from
    # 4.5% to 1.6% — two thirds of the mistakes, for 8.5% of the coverage.
    # Raising it further buys nothing (0.8 and 0.9 both score marginally worse on
    # small denominators) while withholding far more. Errors concentrate sharply:
    # 35.3% of answers below 0.7 were wrong, against 0% from 0.70-0.89.
    #
    # Only affects providers that report a confidence. The LLM path returns a
    # bare category name and is never gated, so this changes nothing for anyone
    # who has not selected Jev.
    add_column :families, :categorization_confidence_threshold, :decimal, precision: 3, scale: 2, default: 0.7, null: false
    # Shadow stays off: it runs a second provider per batch and doubles spend.
    add_column :families, :categorization_shadow_rate, :decimal, precision: 3, scale: 2, default: 0, null: false

    add_check_constraint :families,
                         "categorization_confidence_threshold >= 0 AND categorization_confidence_threshold <= 1",
                         name: "chk_families_categorization_confidence_threshold"
    add_check_constraint :families,
                         "categorization_shadow_rate >= 0 AND categorization_shadow_rate <= 1",
                         name: "chk_families_categorization_shadow_rate"
  end
end
