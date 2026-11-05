# frozen_string_literal: true

class Assistant::Function::UnsplitTransaction < Assistant::Function
  include Assistant::Function::SplitSupport

  class << self
    def name
      "unsplit_transaction"
    end

    def description
      <<~INSTRUCTIONS
        Undoes a split made with split_transaction or the app's split editor:
        deletes the parts and restores the original transaction so it counts
        in budgets and reports again.

        Pass the id of the original or of any of its parts.
      INSTRUCTIONS
    end
  end

  def params_schema
    build_schema(
      required: [ "id" ],
      properties: {
        id: {
          type: "string",
          description: "Transaction ID from get_transactions"
        }
      }
    )
  end

  def call(params = {})
    found = find_split_transaction(params["id"])
    return error("not_found", "Transaction with id '#{params["id"]}' not found.") unless found

    _transaction, entry = resolve_split_parent(found)
    return error("not_authorized", "You do not have permission to unsplit this transaction.") unless permitted_to_split?(entry.account)
    return error("not_split", "Transaction is not split.") unless entry.unsplit_once!

    entry.sync_account_later

    {
      success: true,
      transaction: serialize_split(entry.reload),
      message: "Transaction '#{entry.name}' is no longer split."
    }
  rescue ActiveRecord::RecordInvalid => e
    error("validation_failed", e.record.errors.full_messages.presence&.join("; ") || e.message)
  end
end
