# The actions that hand transactions to an AI provider. A rule acts on the
# whole family, but the provider only gets what the person behind the run
# could categorize by hand (Account.annotatable_by), plus the accounts every
# active member can see. A run nobody started (after a sync) gets only the
# latter. Admins are not exempt, as on /accounts.
module Rule::AiEnrichment
  def actionable_scope(scope, user:)
    accounts = rule.family.accounts
    shared = scope.where(entry: { account_id: accounts.accessible_by_all_active_members.select(:id) })
    return shared unless user

    shared.or(scope.where(entry: { account_id: accounts.annotatable_by(user).select(:id) }))
  end
end
