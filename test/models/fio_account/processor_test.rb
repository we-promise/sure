require "test_helper"

class FioAccount::ProcessorTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @fio_item = FioItem.create!(family: @family, name: "Test Fio", token: "fio-token")
    @fio_account = FioAccount.create!(
      fio_item: @fio_item,
      name: "Fio banka 2400222222",
      fio_account_id: "2400222222",
      currency: "CZK",
      current_balance: 8_642.5
    )
  end

  test "writes the statement balance and currency onto the linked account" do
    account = link(accountable: Depository.new(subtype: "checking"), currency: "USD", balance: 0)

    FioAccount::Processor.new(@fio_account).process

    account.reload
    assert_equal 8_642.5, account.balance
    assert_equal 8_642.5, account.cash_balance
    assert_equal "CZK", account.currency
  end

  # Fio reports a drawn overdraft, loan or mortgage as a negative balance; Sure holds a
  # liability as a positive one, so the same number would otherwise show as a debt of
  # minus several hundred thousand crowns.
  test "stores a loan's negative balance as a positive liability" do
    @fio_account.update!(current_balance: -1_250_000.0)
    account = link(accountable: Loan.new, currency: "CZK", balance: 0)

    FioAccount::Processor.new(@fio_account).process

    assert_equal 1_250_000.0, account.reload.balance
  end

  test "does nothing for an account the user has not linked" do
    assert_nil FioAccount::Processor.new(@fio_account).process
  end

  test "imports the stored movements into the linked account" do
    account = link(accountable: Depository.new(subtype: "checking"), currency: "CZK", balance: 0)
    @fio_account.update!(raw_transactions_payload: [ {
      "column22" => { "value" => 1_148_734_530, "id" => 22 },
      "column0" => { "value" => 1_781_474_400_000, "id" => 0 },
      "column1" => { "value" => -239.0, "id" => 1 },
      "column14" => { "value" => "CZK", "id" => 14 }
    } ])

    FioAccount::Processor.new(@fio_account).process

    entry = account.reload.entries.sole
    assert_equal "fio_1148734530", entry.external_id
    assert_equal 239.0, entry.amount
  end

  private

    def link(accountable:, currency:, balance:)
      account = Account.create!(
        family: @family, name: "Fio", accountable: accountable, balance: balance, currency: currency
      )
      AccountProvider.create!(account: account, provider: @fio_account)
      @fio_account.reload
      account
    end
end
