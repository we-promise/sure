class RuleNotificationMailer < ApplicationMailer
  def digest(rule:, transactions:)
    @rule = rule
    @transactions = transactions
    @family = rule.family
    @transactions_url = transactions_url

    # Admins only: the digest contains transaction details, so never widen the
    # recipient set to a regular member/guest. super_admin is the family owner
    # and must be included (see User#admin?); a self-hosted family is commonly a
    # single super_admin. Skip delivery entirely when there is no admin.
    recipient = @family.users.find_by(role: %w[admin super_admin])
    return if recipient.nil?

    mail(
      to: recipient.email,
      subject: t(".subject", count: transactions.size, product_name: product_name)
    )
  end
end
