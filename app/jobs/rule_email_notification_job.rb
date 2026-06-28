class RuleEmailNotificationJob < ApplicationJob
  queue_as :medium_priority

  def perform(rule_id, transaction_ids)
    rule = Rule.find_by(id: rule_id)
    return unless rule

    transactions = rule.family.transactions
                       .where(id: transaction_ids)
                       .includes(entry: :account)
                       .to_a
                       .sort_by { |txn| txn.entry.date }
                       .reverse

    RuleNotificationMailer.digest(rule: rule, transactions: transactions).deliver_now if transactions.any?
  end
end
