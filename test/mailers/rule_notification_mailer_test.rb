require "test_helper"

class RuleNotificationMailerTest < ActionMailer::TestCase
  include EntriesTestHelper

  test "digest" do
    rule = rules(:one)
    rule.update!(name: "Coffee rule")
    family = rule.family
    admin = family.users.find_by(role: %w[admin super_admin])
    account = family.accounts.create!(name: "Mailer test", balance: 100, currency: "USD", accountable: Depository.new)
    txn = create_transaction(date: Date.current, account: account, amount: 100, name: "Coffee").transaction

    mail = RuleNotificationMailer.digest(rule: rule, transactions: [ txn ])

    # The mailer derives the recipient from rule.family, so assert against that
    # admin explicitly rather than an unrelated fixture.
    assert_equal [ admin.email ], mail.to
    assert_equal I18n.t(
      "rule_notification_mailer.digest.subject",
      count: 1,
      product_name: Rails.configuration.x.product_name
    ), mail.subject
    assert_match "Coffee", mail.body.encoded

    # The "View transactions" CTA must link to the transactions page in both parts.
    html = mail.html_part.body.encoded
    text = mail.text_part.body.encoded
    assert_match I18n.t("rule_notification_mailer.digest.cta"), html
    assert_match %r{/transactions}, html
    assert_match %r{/transactions}, text
  end

  test "digest is delivered to the super_admin owner when there is no plain admin" do
    # A self-hosted family is commonly a single super_admin (the owner) with no
    # :admin user. The owner must still receive the digest.
    family = Family.create!(name: "Solo owner family", currency: "USD")
    owner = User.create!(family: family, email: "solo-owner@example.com", password: "password123", role: :super_admin)
    account = family.accounts.create!(name: "Mailer test", balance: 100, currency: "USD", accountable: Depository.new)
    txn = create_transaction(date: Date.current, account: account, amount: 100, name: "Coffee").transaction
    rule = Rule.new(family: family, resource_type: "transaction", name: "Coffee rule")

    mail = RuleNotificationMailer.digest(rule: rule, transactions: [ txn ])

    assert_equal [ owner.email ], mail.to
  end

  test "digest is skipped when the family has no admin or super_admin" do
    # Transaction details must never go to a regular member/guest.
    family = Family.create!(name: "No-admin family", currency: "USD")
    User.create!(family: family, email: "member-only@example.com", password: "password123", role: :member)
    account = family.accounts.create!(name: "Mailer test", balance: 100, currency: "USD", accountable: Depository.new)
    txn = create_transaction(date: Date.current, account: account, amount: 100, name: "Coffee").transaction
    rule = Rule.new(family: family, resource_type: "transaction", name: "Coffee rule")

    assert_no_emails do
      RuleNotificationMailer.digest(rule: rule, transactions: [ txn ]).deliver_now
    end
  end
end
