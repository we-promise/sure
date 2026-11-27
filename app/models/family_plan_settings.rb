# Paycheck Flow Planner (M2): how a family's pooled leftover (fun money) is
# attributed between partners. income_ratio splits by each partner's share of
# total income, equal_split 1/N; custom is v2 and its rules live in
# `custom_rules`.
class FamilyPlanSettings < ApplicationRecord
  enum :leftover_distribution, { income_ratio: "income_ratio", equal_split: "equal_split", custom: "custom" }

  belongs_to :family

  def self.for_family(family)
    find_by(family: family) || new(family: family)
  end
end
