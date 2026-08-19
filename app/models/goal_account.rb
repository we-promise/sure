class GoalAccount < ApplicationRecord
  belongs_to :goal
  belongs_to :account

  validates :account_id, uniqueness: { scope: :goal_id }
  validates :allocated_amount,
            numericality: { greater_than_or_equal_to: 0 },
            allow_nil: true

  # nil allocated_amount means "dedicate the whole account balance" (the v1
  # default). A set amount earmarks a fixed slice of the account toward this
  # goal. The share that actually counts toward the goal — after sibling
  # earmarks and the pro-rata over-allocation haircut — is computed by
  # Goal#current_balance, which owns the shared-pool math.
  def whole_account?
    allocated_amount.nil?
  end
end
