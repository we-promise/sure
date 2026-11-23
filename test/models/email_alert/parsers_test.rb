require "test_helper"

class EmailAlert::ParsersTest < ActiveSupport::TestCase
  include EmailAlertsTestHelper

  test "GTBank credit" do
    alert = parse("gtbank_credit")

    assert_equal "gtbank", alert.parser_key
    assert_equal "4821", alert.account_identifier
    assert_equal "GTBank ••4821", alert.account_name
    assert_equal :credit, alert.direction
    assert_equal BigDecimal("250000"), alert.amount
    assert_equal BigDecimal("-250000"), alert.entry_amount
    assert_equal "NGN", alert.currency
    assert_equal BigDecimal("312450.75"), alert.balance
    assert_equal "00001226111915154200", alert.reference
    assert_match(/ACME SUPPLIES LTD/, alert.description)
    assert_equal Time.utc(2026, 11, 19, 14, 15, 42), alert.occurred_at.utc
    assert_nil alert.category_hint
  end

  test "GTBank fee alert with empty fields" do
    alert = parse("gtbank_debit_commission")

    assert_equal :debit, alert.direction
    assert_equal BigDecimal("25"), alert.entry_amount
    assert_equal "Commission on NIP Transfer", alert.description
    assert_nil alert.reference
    assert_equal :bank_fees, alert.category_hint
    assert_equal "CHARGES", alert.details[:remarks]
  end

  test "OPay transfer uses the body time, not the Date header offset" do
    alert = parse("opay_transfer")

    assert_equal "opay", alert.parser_key
    assert_equal "wallet", alert.account_identifier
    assert_equal BigDecimal("1500"), alert.entry_amount
    assert_equal BigDecimal("8254.29"), alert.balance
    assert_equal "Transfer to TUNDE BAKARE (Kuda)", alert.description
    assert_equal "261122010100000000000001", alert.reference
    assert_equal Time.utc(2026, 11, 22, 17, 42, 5), alert.occurred_at.utc
  end

  test "OPay merchant payment" do
    alert = parse("opay_payment")

    assert_equal "Payment to Paystack Payment Limited", alert.description
    assert_equal BigDecimal("12500"), alert.amount
    assert_equal BigDecimal("44120.10"), alert.balance
    assert_equal "paystack_000000_abcde", alert.details[:merchant_order_number]
  end

  test "OPay non-transaction mail is not an alert" do
    assert_nil parse("opay_otp")
  end

  test "Grey withdrawal debits the tendered amount from the tendered currency wallet" do
    alert = parse("grey_withdrawal")

    assert_equal "usd", alert.account_identifier
    assert_equal "Grey USD", alert.account_name
    assert_equal "USD", alert.currency
    assert_equal BigDecimal("4.10"), alert.entry_amount
    assert_equal "₦5,600.00", alert.details[:amount_received]
    assert_equal "Withdrawal to MAMA PUT KITCHEN (Moniepoint Microfinance Bank)", alert.description
    assert_equal Time.utc(2026, 11, 3, 23, 37), alert.occurred_at.utc
    assert_nil alert.balance
  end

  test "Grey card spend and wallet funding" do
    card = parse("grey_card")
    assert_equal "Card: Hetzner", card.description
    assert_equal BigDecimal("9.45"), card.entry_amount

    funding = parse("grey_funding")
    assert_equal :credit, funding.direction
    assert_equal BigDecimal("-795"), funding.entry_amount
    assert_equal "Grey wallet funding", funding.description
  end

  test "external ids are stable and distinguish fee alerts" do
    assert_equal parse("gtbank_credit").external_id, parse("gtbank_credit").external_id
    assert_not_equal parse("gtbank_credit").external_id, parse("gtbank_debit_commission").external_id
    assert_match(/\Agtbank_\h{32}\z/, parse("gtbank_credit").external_id)
  end

  test "parser lookup is by sender domain" do
    assert_equal EmailAlert::Parsers::Gtbank, EmailAlert::Parsers.for_domain("gtbank.com")
    assert_equal EmailAlert::Parsers::Grey, EmailAlert::Parsers.for_domain("grey.co")
    assert_nil EmailAlert::Parsers.for_domain("gtbank.com.example")
    assert_nil EmailAlert::Parsers.for_domain("example.com")
  end

  private

    def parse(name)
      message = EmailAlert::MimeMessage.new(email_alert_fixture(name))
      EmailAlert::Parsers.for_domain(message.from_domain).new(message).parse
    end
end
