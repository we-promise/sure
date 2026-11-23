# The actions that hand transactions to an AI provider. A rule acts on the
# whole family, but the provider only gets what the person behind the run
# could categorize by hand (Account.annotatable_by), plus the accounts every
# active member can see. A run nobody started (after a sync) gets only the
# latter. Admins are not exempt, as on /accounts.
#
# Checked twice: when the rule queues the AI jobs, and again by each job right
# before it calls the provider, so a share revoked in between is respected.
module Rule::AiEnrichment
  # @param scope [ActiveRecord::Relation<Transaction>] joined to its entry
  def self.scope(scope, family:, user:)
    accounts = family.accounts
    shared = scope.where(entry: { account_id: accounts.accessible_by_all_active_members.select(:id) })
    return shared unless user

    shared.or(scope.where(entry: { account_id: accounts.annotatable_by(user).select(:id) }))
  end

  # @return [Array<String>] the ids of +transaction_ids+ the provider may still get, in their order
  def self.permitted_ids(family, transaction_ids, user:)
    permitted = scope(Transaction.joins(:entry).where(id: transaction_ids), family:, user:).pluck(:id).to_set
    transaction_ids.select { permitted.include?(_1) }
  end

  def run(scope, user:, **options)
    execute(Rule::AiEnrichment.scope(scope, family: rule.family, user:), user:, **options)
  end
end
