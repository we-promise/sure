require "test_helper"

class SharesightAccount::FundingMirrorTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    item = @family.sharesight_items.create!(name: "Sharesight", client_id: "client-id", client_secret: "client-secret")
    @account = @family.accounts.create!(name: "CMC Invest", balance: 0, currency: "AUD", accountable: Investment.new)
    @bank = @family.accounts.create!(name: "CommBank", balance: 0, currency: "AUD", accountable: Depository.new)
    @sharesight_account = item.sharesight_accounts.create!(
      name: "Shares", sharesight_account_id: "42", currency: "AUD", current_balance: 0, cash_balance: 0,
      funding_account: @bank, funding_match_terms: [ "CMC Share Transfer", "CMC Markets" ]
    )
    @sharesight_account.ensure_account_provider!(@account)

    @top_up = bank_transaction(815, "2026-09-01", "CMC Share Transfer 1364731")
    @withdrawal = bank_transaction(-100, "2026-09-15", "Payment from CMC MARKETS")
    @coffee = bank_transaction(5, "2026-09-02", "Coffee")
  end

  test "top-ups and withdrawals are mirrored and linked as transfers" do
    mirror

    top_up = mirror_of(@top_up)
    assert_equal [ BigDecimal("-815"), "Transfer from CommBank", Date.new(2026, 9, 1) ], [ top_up.amount, top_up.name, top_up.date ]
    assert top_up.entryable.transfer.confirmed?
    assert_equal "investment_contribution", @top_up.entryable.reload.kind

    assert_equal BigDecimal("100"), mirror_of(@withdrawal).amount
    assert_nil mirror_of(@coffee, required: false)
  end

  test "a failed run keeps the mirrors it couldn't refresh" do
    mirror
    SharesightAccount::FundingMirror.any_instance.stubs(:link_transfer!).raises(StandardError, "database blip")

    mirror

    assert mirror_of(@top_up)
    assert @top_up.entryable.reload.transfer&.confirmed?
  end

  test "bank transactions already paired with another account are left alone" do
    savings = @family.accounts.create!(name: "Savings", balance: 0, currency: "AUD", accountable: Depository.new)
    other_side = savings.entries.create!(name: "From CommBank", date: Date.new(2026, 9, 1), amount: -815, currency: "AUD", entryable: Transaction.new)
    Transfer.create!(inflow_transaction: other_side.entryable, outflow_transaction: @top_up.entryable, status: "confirmed")

    mirror

    assert_nil mirror_of(@top_up, required: false)
  end

  test "mirrors stop where the settlement account takes over and go when the terms change" do
    mirror
    @sharesight_account.update!(cash_mode: "settlement", settlement_account: @bank, settlement_starts_on: Date.new(2026, 9, 10))

    mirror

    assert mirror_of(@top_up)
    assert_nil mirror_of(@withdrawal, required: false)

    @sharesight_account.update!(funding_match_terms: [])
    mirror

    assert_empty @account.entries.where("external_id LIKE 'sharesight_funding_%'")
    assert_nil @top_up.entryable.reload.transfer
  end

  private

    def mirror
      SharesightAccount::FundingMirror.new(@sharesight_account.reload).mirror
    end

    def bank_transaction(amount, date, name)
      @bank.entries.create!(name: name, date: Date.parse(date), amount: amount, currency: "AUD", entryable: Transaction.new)
    end

    def mirror_of(bank_entry, required: true)
      scope = @account.entries.where(external_id: "sharesight_funding_#{bank_entry.id}")
      required ? scope.first! : scope.first
    end
end
