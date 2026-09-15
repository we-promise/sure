class Assistant::Function::DeleteGoal < Assistant::Function
  class << self
    def name = "delete_goal"

    def description
      "Permanently deletes an archived goal. Use update_goal with state=archived first."
    end
  end

  def params_schema
    build_schema(
      required: [ "id" ],
      properties: { id: { type: "string", description: "Goal ID from get_goals" } }
    )
  end

  def call(params = {})
    goal = valid_uuid?(params["id"]) ? family.goals.find_by(id: params["id"]) : nil
    return error("not_found", "Goal not found.") unless goal

    Goal.transaction do
      goal.lock!
      unless goal.archived?
        next error("archive_first", "Archive the goal with update_goal before deleting it.")
      end

      id = goal.id
      name = goal.name
      goal.destroy!
      { success: true, deleted_goal_id: id, message: "Goal '#{name}' deleted." }
    end
  rescue ActiveRecord::RecordNotFound
    error("not_found", "Goal not found.")
  rescue ActiveRecord::RecordNotDestroyed => e
    error("delete_failed", e.record.errors.full_messages.join("; "))
  end

  private
    def error(key, message)
      { success: false, error: key, message: message }
    end
end
