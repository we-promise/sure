class Goal::RetirementStatement < ApplicationRecord
  include Monetizable

  self.table_name = "goal_retirement_statements"

  belongs_to :goal_retirement, class_name: "Goal::Retirement", foreign_key: :goal_retirement_id
  belongs_to :pension_source

  validates :received_on, presence: true
  validates :projected_monthly_amount, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :projected_currency, presence: true
  # Prevent IDOR: a statement may only reference a pension source from its
  # own plan, even if a crafted request supplies another plan's source id.
  validate :pension_source_belongs_to_plan

  # Append-only audit: soft-deleted rows stay in the table for history but
  # drop out of every normal read. Edits go through soft_replace!.
  default_scope { where(deleted: false) }

  scope :chronological, -> { order(:received_on) }

  monetize :projected_monthly_amount

  # Δ in pension points vs the prior active statement for the same source.
  # nil for the earliest row (renders "—" in the journal).
  def points_delta
    return nil if current_points.nil?

    prior = pension_source.statements
                          .where("received_on < ?", received_on)
                          .chronological
                          .last
    return nil if prior.nil? || prior.current_points.nil?

    current_points - prior.current_points
  end

  # Edit = soft-delete this row + insert a replacement, preserving the
  # audit trail. Returns the new statement.
  def soft_replace!(attrs)
    new_statement = nil
    self.class.transaction do
      # update_column is deliberate: flip the soft-delete flag without
      # re-running validations/callbacks on the archived row.
      update_column(:deleted, true)
      new_statement = pension_source.statements.create!(
        attributes
          .except("id", "deleted", "created_at", "updated_at")
          .merge(attrs.stringify_keys)
      )
    end
    new_statement
  end

  private
    def pension_source_belongs_to_plan
      return if pension_source.nil? || goal_retirement_id.nil?
      return if pension_source.goal_retirement_id == goal_retirement_id

      errors.add(:pension_source, :must_belong_to_plan)
    end

    def monetizable_currency
      projected_currency
    end
end
