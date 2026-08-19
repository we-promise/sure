class Assistant::Function::DeleteAccount < Assistant::Function
  class << self
    def name = "delete_account"

    def description
      <<~INSTRUCTIONS
        Schedules a writable manual account and its financial data for deletion.
        Linked provider accounts must be unlinked in Sure before they can be deleted.
      INSTRUCTIONS
    end
  end

  def params_schema
    build_schema(
      required: [ "id" ],
      properties: {
        id: { type: "string", description: "Account ID from get_accounts" }
      }
    )
  end

  def call(params = {})
    account = find_account(params["id"])
    return error("not_found", "Writable account not found.") unless account

    result = nil
    Account.transaction do
      account.lock!
      unless account.permission_for(user).in?([ :owner, :full_control ]) && !account.pending_deletion?
        result = error("not_found", "Writable account not found.")
        next
      end
      if account.linked?
        result = error("linked_account", "Linked accounts must be unlinked in Sure before deletion.")
        next
      end

      account.destroy_later
    end
    return result if result

    {
      success: true,
      deleted_account_id: account.id,
      status: account.reload.status,
      message: "Account '#{account.name}' scheduled for deletion."
    }
  rescue AASM::InvalidTransition, ActiveRecord::RecordInvalid => e
    error("delete_failed", e.message)
  end

  private
    def find_account(id)
      return nil unless valid_uuid?(id)

      family.accounts.writable_by(user).where.not(status: :pending_deletion).find_by(id: id)
    end

    def error(key, message)
      { success: false, error: key, message: message }
    end
end
