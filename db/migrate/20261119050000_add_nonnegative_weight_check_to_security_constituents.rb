class AddNonnegativeWeightCheckToSecurityConstituents < ActiveRecord::Migration[8.1]
  # Bulk inserts skip the model's validation, and a negative weight would make
  # the listed share of a long-only fund negative. Zero and unknown stay valid.
  def change
    add_check_constraint :security_constituents, "weight IS NULL OR weight >= 0",
      name: "chk_security_constituents_weight_nonnegative"
  end
end
