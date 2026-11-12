# M2 PR#2b (Sure Paycheck Flow redesign): one allocation pulled out of a
# source bank on the family's planning diagram -- a bill, debt payment,
# savings target, or fun money. The mode decides how much it gets per
# paycheck; the bank-level resolution order is fixed and non-configurable
# (required -> specific -> percent of the bank's leftover pool -> leftover
# split equally), which the planner applies: PaycheckFlowPlanner#plan_graph.
class PlanAllocation < ApplicationRecord
  # weekly | biweekly | monthly | quarterly | yearly -- autofilled from the
  # linked recurring transaction's interval/weekday, editable in the dialog.
  CADENCES = %w[weekly biweekly monthly quarterly yearly].freeze

  # bill | debt | savings | fun_money. Bills and debts are REQUIRED by
  # definition (paid first, never the over-plan flag target); savings and
  # fun_money are what the over-plan flag measures against.
  enum :kind, { bill: "bill", debt: "debt", savings: "savings", fun_money: "fun_money" }

  # required: value_cents OR a linked recurring transaction (amount from its
  #   monthly_equivalent_amount). specific: per-paycheck hard number.
  # percent: share of the bank's leftover pool. leftover: splits the bank's
  #   final residual equally.
  enum :mode, { required: "required", specific: "specific", percent: "percent", leftover: "leftover" }

  belongs_to :family
  # The source bank the money is pulled from (the diagram's "SOURCE BANK").
  # Optional (owner review round 3, R3): a bank removed from the plan leaves
  # its allocations behind, unassigned ("No Assignment" marker) — they are
  # excluded from resolution until re-assigned.
  # The source bank the money is pulled from (the diagram's "SOURCE BANK").
  # Optional (owner review round 3, R3): a bank removed from the plan leaves
  # its allocations behind, unassigned ("No Assignment" marker) — they are
  # excluded from resolution until re-assigned. For kind "savings" (owner
  # round 10, issue 4) this SAME field is the bucket's associated account:
  # the planner resolution and the Sankey band both key off it, and the
  # dialog labels it "Which Account is this Savings Bucket Associated to".
  belongs_to :account, optional: true
  # The detected bill/debt this allocation represents (autofill source).
  belongs_to :recurring_transaction, optional: true
  # Round 16 (owner note 2): the Sure category whose color the diagram uses
  # for this allocation's band. Optional — an allocation without a category
  # renders with no color (nil), never a fabricated one.
  belongs_to :category, optional: true

  validates :name, presence: true
  validates :cadence, inclusion: { in: CADENCES }, allow_nil: true
  validate :value_matches_mode
  validate :references_belong_to_family

  # Required-mode amounts resolve from the linked transaction's
  # monthly-equivalent amount when no explicit value_cents is set.
  def resolved_monthly_amount
    return value_cents if value_cents.present?

    return nil unless recurring_transaction

    recurring_transaction.monthly_equivalent_amount.amount * 100
  end

  private
    # Mode-specific value rules (the DB check constraint
    # chk_plan_allocations_value_mode enforces the same shape at the edge).
    def value_matches_mode
      case mode
      when "required"
        if kind == "savings"
          # Round 10 issue 4: a savings bucket's monthly figure is always
          # TYPED (the dialog hides the detected-bill link for kind
          # "savings"), so a linked recurring transaction is no substitute
          # — the explicit monthly amount is required.
          errors.add(:value_cents, "is required for a savings bucket") if value_cents.nil?
        elsif value_cents.nil? && recurring_transaction_id.blank?
          errors.add(:value_cents, "is required unless a recurring transaction is linked")
        end
        errors.add(:value_percent, "is not allowed for this mode") if value_percent.present?
      when "specific"
        if value_cents.blank? || value_cents <= 0
          errors.add(:value_cents, :numericality, greater_than: 0)
        end
        errors.add(:value_percent, "is not allowed for this mode") if value_percent.present?
      when "percent"
        if value_percent.blank? || value_percent <= 0 || value_percent > 1
          errors.add(:value_percent, :numericality, greater_than: 0, less_than_or_equal_to: 1)
        end
        errors.add(:value_cents, "is not allowed for this mode") if value_cents.present?
      when "leftover"
        errors.add(:value_cents, "is not allowed for this mode") if value_cents.present?
        errors.add(:value_percent, "is not allowed for this mode") if value_percent.present?
      end
    end

    # House pattern (account.rb owner_belongs_to_family): an allocation may
    # only reference the source bank and the recurring transaction of its
    # own family.
    def references_belong_to_family
      return if family_id.blank?

      errors.add(:account, "must belong to the same family") if
        account.present? && account.family_id != family_id

      errors.add(:recurring_transaction, "must belong to the same family") if
        recurring_transaction.present? && recurring_transaction.family_id != family_id

      errors.add(:category, "must belong to the same family") if
        category.present? && category.family_id != family_id
    end
end
