require "test_helper"

class OpenBankingIoItem::UnlinkingTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @item = OpenBankingIoItem.create!(
      family: @family, name: "Test connection",
      api_base_url: "https://open-banking.io", api_key: "k", private_key: "p"
    )
    @provider_account = @item.open_banking_io_accounts.create!(
      account_id: "acc-1", name: "Everyday", currency: "EUR"
    )
    @account = @family.accounts.create!(
      name: "Everyday", balance: 100, currency: "EUR", accountable: Depository.new
    )
    @link = AccountProvider.create!(account: @account, provider: @provider_account)
  end

  test "a dry run reports the links without destroying anything" do
    results = @item.unlink_all!(dry_run: true)

    assert_equal 1, results.size
    assert_equal @provider_account.id, results.first[:provider_account_id]
    assert_equal [ @link.id ], results.first[:provider_link_ids]
    assert AccountProvider.exists?(@link.id)
  end

  # Unlinking must leave the user's Account and its history intact -- only the provider
  # link goes away, so the account becomes a manual one rather than disappearing.
  test "destroys the provider link but keeps the account" do
    @item.unlink_all!(dry_run: false)

    assert_not AccountProvider.exists?(@link.id)
    assert Account.exists?(@account.id)
    assert_nil @provider_account.reload.account_provider
  end

  test "detaches holdings from the link before destroying it" do
    security = Security.create!(ticker: "OBIO#{SecureRandom.hex(3)}", name: "Test Security")
    holding = Holding.create!(
      account: @account, security: security, date: Date.current,
      qty: 1, price: 10, amount: 10, currency: "EUR", account_provider: @link
    )

    @item.unlink_all!(dry_run: false)

    assert Holding.exists?(holding.id), "the holding must survive the unlink"
    assert_nil holding.reload.account_provider_id
  end

  # One provider account failing must be recorded and must not abort the rest.
  test "records a failure per account and continues" do
    second_provider_account = @item.open_banking_io_accounts.create!(
      account_id: "acc-2", name: "Savings", currency: "EUR"
    )
    second_account = @family.accounts.create!(
      name: "Savings", balance: 10, currency: "EUR", accountable: Depository.new
    )
    second_link = AccountProvider.create!(account: second_account, provider: second_provider_account)

    AccountProvider.any_instance.stubs(:destroy!).raises(ActiveRecord::RecordNotDestroyed.new("nope"))

    assert_difference "DebugLogEntry.count", 2 do
      results = @item.unlink_all!(dry_run: false)
      assert_equal 2, results.size
      assert results.all? { |r| r[:error].present? }
    end

    assert AccountProvider.exists?(@link.id)
    assert AccountProvider.exists?(second_link.id)
  end

  # The scope is family-bound, so one family's unlink can never touch another's links.
  test "ignores links belonging to another family" do
    other_account = families(:empty).accounts.create!(
      name: "Someone else", balance: 5, currency: "EUR", accountable: Depository.new
    )
    other_provider_account = @item.open_banking_io_accounts.create!(
      account_id: "acc-3", name: "Foreign", currency: "EUR"
    )
    other_link = AccountProvider.create!(account: other_account, provider: other_provider_account)

    @item.unlink_all!(dry_run: false)

    assert AccountProvider.exists?(other_link.id)
  end
end
