# Probes for which transactions a rule's AI actions hand to the provider.
# Needs EntriesTestHelper and ActiveJob::TestHelper.
module AiRuleScopeTestHelper
  # One uncategorized transaction in each kind of account of dylan_family:
  # one the admin shares with the member, and one each keeps private.
  def ai_scope_probes
    member_account = families(:dylan_family).accounts.create!(name: "Member private", balance: 0, currency: "USD",
                                                              owner: users(:family_member), accountable: Depository.new)

    {
      shared: create_transaction(account: accounts(:depository), name: "AI scope probe shared").entryable_id,
      admin_private: create_transaction(account: accounts(:connected), name: "AI scope probe admin").entryable_id,
      member_private: create_transaction(account: member_account, name: "AI scope probe member").entryable_id
    }
  end

  def ai_scope_rule(action_type = "auto_categorize", active: true)
    families(:dylan_family).rules.create!(
      name: "AI scope",
      resource_type: "transaction",
      active: active,
      conditions: [ Rule::Condition.new(condition_type: "transaction_name", operator: "like", value: "AI scope probe") ],
      actions: [ Rule::Action.new(action_type: action_type) ]
    )
  end

  # The transaction ids in the AI jobs enqueued so far.
  def ai_batch_ids(job_class = AutoCategorizeJob)
    enqueued_jobs.select { |job| job["job_class"] == job_class.name }
                 .flat_map { |job| job["arguments"].last["transaction_ids"] }
                 .sort
  end
end
