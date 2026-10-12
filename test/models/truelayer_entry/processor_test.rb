require "test_helper"

class TruelayerEntry::ProcessorTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @item = TruelayerItem.create!(family: @family, name: "Acme Bank", client_id: "sure-test", client_secret: "secret", refresh_token: "rt")
  end

  test "imports a current account debit as an outflow" do
    truelayer_account, account = linked_account(kind: "account", accountable: Depository.new)

    entry = process(truelayer_account, amount: -12.5, merchant_name: "Tesco", description: "TESCO STORES 1234")

    assert_equal 12.5, entry.amount
    assert_equal "Tesco", entry.name
    assert_equal "TESCO STORES 1234", entry.notes
    assert_equal "truelayer", entry.source
    assert_equal account, entry.account
    assert_equal "Tesco", entry.transaction.merchant.name
  end

  test "imports a card charge as an outflow and a card refund as an inflow" do
    truelayer_account, _account = linked_account(kind: "card", accountable: CreditCard.new)

    charge = process(truelayer_account, id: "charge", amount: 30)
    refund = process(truelayer_account, id: "refund", amount: -5)

    assert_equal 30, charge.amount
    assert_equal(-5, refund.amount)
  end

  test "keys entries on the normalised provider transaction id when present" do
    truelayer_account, _account = linked_account(kind: "account", accountable: Depository.new)

    with_normalised = process(truelayer_account, id: "tl-1", normalised_provider_transaction_id: "bank-1")
    without = process(truelayer_account, id: "tl-2")

    assert_equal "truelayer_bank-1", with_normalised.external_id
    assert_equal "truelayer_tl-2", without.external_id
  end

  test "reprocessing the same transaction updates the existing entry" do
    truelayer_account, account = linked_account(kind: "account", accountable: Depository.new)

    process(truelayer_account, id: "tl-1", amount: -10)
    assert_no_difference -> { account.entries.count } do
      process(truelayer_account, id: "tl-1", amount: -11)
    end
    assert_equal 11, account.entries.find_by(external_id: "truelayer_tl-1").amount
  end

  test "uses the bank's calendar date from the timestamp" do
    truelayer_account, _account = linked_account(kind: "account", accountable: Depository.new)

    entry = process(truelayer_account, timestamp: "2026-03-31T23:30:00+00:00")

    assert_equal Date.new(2026, 3, 31), entry.date
  end

  test "falls back to the description when there is no merchant name" do
    truelayer_account, _account = linked_account(kind: "account", accountable: Depository.new)

    entry = process(truelayer_account, merchant_name: nil, description: "  DIRECT DEBIT COUNCIL TAX ")

    assert_equal "DIRECT DEBIT COUNCIL TAX", entry.name
  end

  test "creates no merchant from a bare bank description" do
    truelayer_account, _account = linked_account(kind: "account", accountable: Depository.new)

    entry = process(truelayer_account, merchant_name: nil, description: "FPS J SMITH REF 20260301")

    assert_equal "FPS J SMITH REF 20260301", entry.name
    assert_nil entry.transaction.merchant
  end

  test "rejects a transaction without a usable amount" do
    truelayer_account, _account = linked_account(kind: "account", accountable: Depository.new)
    transaction = { transaction_id: "tl-blank", timestamp: "2026-03-01T10:00:00+00:00", amount: "", currency: "GBP", description: "SHOP" }

    error = assert_raises(ArgumentError) { TruelayerEntry::Processor.new(transaction, truelayer_account: truelayer_account).process }

    assert_match(/no usable amount/, error.message)
  end

  private

    def linked_account(kind:, accountable:)
      truelayer_account = @item.truelayer_accounts.create!(account_id: "acc-#{kind}", account_kind: kind, name: "Acc", currency: "GBP")
      account = Account.create!(family: @family, name: "Acc", balance: 0, currency: "GBP", accountable: accountable)
      AccountProvider.create!(account: account, provider: truelayer_account)
      [ truelayer_account.reload, account ]
    end

    def process(truelayer_account, id: "tl-#{SecureRandom.hex(4)}", amount: -1, merchant_name: "Shop", description: "SHOP", timestamp: "2026-03-01T10:00:00+00:00", **extra)
      transaction = {
        transaction_id: id,
        timestamp: timestamp,
        amount: amount,
        currency: "GBP",
        description: description,
        merchant_name: merchant_name,
        transaction_type: amount.negative? ? "DEBIT" : "CREDIT"
      }.merge(extra).compact
      TruelayerEntry::Processor.new(transaction, truelayer_account: truelayer_account).process
    end
end
