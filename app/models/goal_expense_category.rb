# Which expenses a "N months of expenses" reserve counts. Selecting none keeps
# the plain meaning — every expense — so this table is empty for a reserve that
# has never been narrowed.
class GoalExpenseCategory < ApplicationRecord
  belongs_to :goal
  belongs_to :category

  validates :category_id, uniqueness: { scope: :goal_id }

  validate :category_must_belong_to_family

  private
    def category_must_belong_to_family
      return if category.nil? || goal&.family_id.nil?
      return if category.family_id == goal.family_id

      errors.add(:category, :must_belong_to_family)
    end
end
