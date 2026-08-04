class Assistant::Function::GetGoals < Assistant::Function
  class << self
    def name = "get_goals"

    def description
      "Lists family goals with stable ids and linked account ids for update_goal and delete_goal."
    end
  end

  def call(_params = {})
    accessible_ids = user.accessible_accounts.visible.select(:id)
    goals = family.goals.includes(:goal_accounts, :linked_accounts).alphabetically.map do |goal|
      linked_accounts = goal.linked_accounts.select { |account| accessible_ids.exists?(id: account.id) }
      {
        id: goal.id,
        name: goal.name,
        target_amount: goal.target_amount,
        currency: goal.currency,
        target_date: goal.target_date&.iso8601,
        notes: goal.notes,
        state: goal.state,
        linked_accounts: linked_accounts.map { |account| { id: account.id, name: account.name, currency: account.currency } }
      }
    end

    { goals: goals }
  end
end
