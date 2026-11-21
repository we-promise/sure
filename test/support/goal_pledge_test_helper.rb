module GoalPledgeTestHelper
  # An open transfer pledge on an account linked to a goal.
  def open_transfer_pledge(account, amount:, goal: goals(:vacation_italy))
    goal.goal_accounts.find_or_create_by!(account: account)
    GoalPledge.create!(goal: goal, account: account, amount: amount, currency: "USD", kind: "transfer",
                       status: "open", expires_at: 7.days.from_now)
  end
end
