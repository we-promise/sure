module Transaction::Ruleable
  extend ActiveSupport::Concern

  # Offer the "create a rule?" prompt unless an active rule that sets this
  # category would already categorize this transaction. Checking only whether
  # *some* rule targets the category hid the prompt for every category that
  # already had a rule, even when that rule's conditions don't match this
  # transaction (e.g. an "AMAZON" rule and an "AMZN Mktp" payee).
  def eligible_for_category_rule?
    return false if category_id.blank?

    rules.where(active: true, resource_type: "transaction")
         .joins(:actions)
         .where(actions: { action_type: "set_transaction_category", value: category_id })
         .distinct
         .none? { |rule| rule.matches_transaction?(self) }
  end

  private
    def rules
      entry.account.family.rules
    end
end
