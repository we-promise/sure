class RuleNotificationMailer < ApplicationMailer
  def digest(rule:, transactions:)
    @rule = rule
    @transactions = transactions
    @family = rule.family
    @transactions_url = transactions_url

    # Admin-only: the digest contains transaction details, so never widen the
    # recipient set to a non-admin. Skip delivery entirely if there is no admin.
    recipient = @family.users.find_by(role: :admin)
    return if recipient.nil?

    mail(
      to: recipient.email,
      subject: t(".subject", count: transactions.size, product_name: product_name)
    )
  end
end
