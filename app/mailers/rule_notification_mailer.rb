class RuleNotificationMailer < ApplicationMailer
  def digest(rule:, transactions:)
    @rule = rule
    @transactions = transactions
    @family = rule.family
    @transactions_url = transactions_url

    recipient = @family.users.find_by(role: :admin) || @family.users.first
    return if recipient.nil?

    mail(
      to: recipient.email,
      subject: t(".subject", count: transactions.size, product_name: product_name)
    )
  end
end
