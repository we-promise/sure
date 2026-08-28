# Which expenses a "N months of expenses" reserve counts. Selecting none keeps
# the plain meaning — every expense — so this table is empty for a reserve that
# has never been narrowed.
class GoalExpenseCategory < ApplicationRecord
  belongs_to :goal
  belongs_to :category

  validates :category_id, uniqueness: { scope: :goal_id }

  validate :category_must_belong_to_family

  # Losing a selection changes what the reserve counts — losing its ONLY one
  # widens it back to every expense — and the derived target has to follow.
  # Left alone it would keep a figure worked out from spending the goal no
  # longer counts, wearing a label saying it was computed from what it counts.
  #
  # Only on destroy: rows are created through the controller, which already
  # recomputes once the whole selection is assembled rather than once per box.
  after_destroy_commit :refresh_goal_target

  private
    def refresh_goal_target
      # The goal itself is going away; there is nothing left to recompute, and
      # reloading it would raise. A category being deleted is the case this
      # exists for, and reports a different association.
      return if destroyed_by_association&.active_record == Goal

      goal.reload.refresh_target_from_expenses!
    rescue ActiveRecord::RecordNotFound
      nil
    end

    def category_must_belong_to_family
      return if category.nil? || goal&.family_id.nil?
      return if category.family_id == goal.family_id

      errors.add(:category, :must_belong_to_family)
    end
end
