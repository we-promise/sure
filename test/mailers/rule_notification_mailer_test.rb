require "test_helper"

class RuleNotificationMailerTest < ActionMailer::TestCase
  include EntriesTestHelper

  test "digest" do
    family = families(:dylan_family)
    account = family.accounts.create!(name: "Mailer test", balance: 100, currency: "USD", accountable: Depository.new)
    rule = rules(:one)
    rule.update!(name: "Coffee rule")
    txn = create_transaction(date: Date.current, account: account, amount: 100, name: "Coffee").transaction

    mail = RuleNotificationMailer.digest(rule: rule, transactions: [ txn ])

    recipient = family.users.find_by(role: :admin) || family.users.first

    assert_equal [ recipient.email ], mail.to
    assert_equal I18n.t(
      "rule_notification_mailer.digest.subject",
      count: 1,
      product_name: Rails.configuration.x.product_name
    ), mail.subject
    assert_match "Coffee", mail.body.encoded
  end
end
