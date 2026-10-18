require "test_helper"

class DirectaAccountTest < ActiveSupport::TestCase
  setup do
    ActiveRecordEncryptionConfig.stubs(:explicitly_configured?).returns(true)
    Account.any_instance.stubs(:sync_later).returns(nil)
    @family = families(:dylan_family)
    @owner = users(:family_admin)
    @item = DirectaItem.create!(
      family: @family,
      owner: @owner,
      broker_account: "00123",
      account_identity: "00123",
      multi_token: "synthetic-multi-token",
      mono_token: "synthetic-mono-token",
      connection_generation: 0,
      status: :connected
    )
  end

  test "only links an Investment account in the verified brokerage currency" do
    account = @family.accounts.create!(
      accountable: Investment.new(subtype: "brokerage"),
      name: "Directa",
      balance: 0,
      cash_balance: 0,
      currency: "EUR",
      owner: @owner
    )
    provider_account = DirectaAccount.new(directa_item: @item, currency: "EUR")

    assert provider_account.linkable_to?(account)
    refute provider_account.linkable_to?(@family.accounts.create!(
      accountable: Depository.new,
      name: "Cash account",
      balance: 0,
      currency: "EUR",
      owner: @owner
    ))
    refute provider_account.linkable_to?(@family.accounts.create!(
      accountable: Investment.new(subtype: "brokerage"),
      name: "Different currency",
      balance: 0,
      currency: "USD",
      owner: @owner
    ))
  end

  test "refuses an Investment account owned by another family member" do
    provider_account = DirectaItem::Importer.new(@item).import(
      snapshot: provider_snapshot
    ).account.account_providers.sole.provider
    account = provider_account.account
    account.update!(owner: users(:family_member))

    assert_nil provider_account.usable_account
  end

  test "accepts a signed cash component while requiring total value to include it" do
    provider_account = DirectaAccount.new(
      directa_item: @item,
      currency: "EUR",
      current_balance: BigDecimal("40"),
      cash_balance: BigDecimal("-10")
    )

    assert_predicate provider_account, :valid?

    provider_account.current_balance = BigDecimal("-11")
    refute_predicate provider_account, :valid?
    assert_includes provider_account.errors[:current_balance], "cannot be below brokerage cash"
  end

  private

    def provider_snapshot
      Provider::Directa::Snapshot.new(
        account_number: "00123",
        account_identity: "00123",
        connection_generation: 0,
        observed_at: Time.current,
        cash_seen: true,
        positions_complete: true,
        full_photo_complete: true,
        cash: Provider::Directa::Cash.new(
          amount: BigDecimal("100"),
          raw_amount: "100",
          equity_availability: nil,
          equity_margin_availability: nil,
          realtime_availability: nil,
          consolidated_performance: nil,
          raw_fields: [],
          field_sources: Provider::Directa::FIELD_SOURCES
        ),
        positions: [],
        unknown_message_types: []
      )
    end
end
