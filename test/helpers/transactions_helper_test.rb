require "test_helper"

class TransactionsHelperTest < ActionView::TestCase
  test "mask_counterparty_account_value shows only the last 4 characters" do
    assert_equal "•3000", mask_counterparty_account_value("DE89370400440532013000") # pipelock:ignore IBAN
  end

  test "mask_counterparty_account_value leaves a short value unmasked" do
    assert_equal "1234", mask_counterparty_account_value("1234")
  end

  test "mask_counterparty_account_value returns blank values unchanged" do
    assert_nil mask_counterparty_account_value(nil)
    assert_equal "", mask_counterparty_account_value("")
  end

  test "counterparty_account_display labels an IBAN as an IBAN" do
    transaction = Transaction.new(counterparty_iban: "DE89370400440532013000", counterparty_account_id: "ACC-998877") # pipelock:ignore IBAN
    assert_equal [ I18n.t("transactions.show.counterparty_iban_label"), "•3000" ], counterparty_account_display(transaction)
  end

  test "counterparty_account_display gives a non-IBAN account id a neutral label" do
    transaction = Transaction.new(counterparty_account_id: "ACC-998877")
    assert_equal [ I18n.t("transactions.show.counterparty_account_label"), "•8877" ], counterparty_account_display(transaction)
  end

  test "counterparty_account_display returns nil without counterparty data" do
    assert_nil counterparty_account_display(Transaction.new(counterparty_iban: ""))
  end
end
