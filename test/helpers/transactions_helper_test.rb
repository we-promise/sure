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
end
