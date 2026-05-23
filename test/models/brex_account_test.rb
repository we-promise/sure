require "test_helper"

class BrexAccountTest < ActiveSupport::TestCase
  setup do
    @family_a = families(:dylan_family)
    @family_b = families(:empty)

    @item_a = BrexItem.create!(
      family: @family_a,
      name: "Family A Brex",
      token: "token_a",
      base_url: "https://api-staging.brex.com",
      status: "good"
    )

    @item_b = BrexItem.create!(
      family: @family_b,
      name: "Family B Brex",
      token: "token_b",
      base_url: "https://api-staging.brex.com",
      status: "good"
    )
  end

  test "same account_id can be linked under different brex_items" do
    BrexAccount.create!(
      brex_item: @item_a,
      account_id: "shared_brex_acc_1",
      name: "Checking",
      currency: "USD",
      current_balance: 5000
    )

    # A second family connecting the same Brex account must succeed and produce
    # an independent ledger (separate BrexAccount row, separate Account).
    assert_difference "BrexAccount.count", 1 do
      BrexAccount.create!(
        brex_item: @item_b,
        account_id: "shared_brex_acc_1",
        name: "Checking",
        currency: "USD",
        current_balance: 5000
      )
    end
  end

  test "declares raw Brex payloads as encrypted" do
    skip "Encryption not configured" unless BrexAccount.encryption_ready?

    encrypted_attributes = BrexAccount.encrypted_attributes.map(&:to_s)

    assert_includes encrypted_attributes, "raw_payload"
    assert_includes encrypted_attributes, "raw_transactions_payload"
  end

  test "same account_id can be linked under different brex_items in the same family" do
    item_a_2 = BrexItem.create!(
      family: @family_a,
      name: "Family A Second Brex",
      token: "token_a_2",
      base_url: "https://api-staging.brex.com",
      status: "good"
    )

    BrexAccount.create!(
      brex_item: @item_a,
      account_id: "shared_brex_acc_1",
      name: "Checking",
      currency: "USD",
      current_balance: 5000
    )

    assert_difference "BrexAccount.count", 1 do
      BrexAccount.create!(
        brex_item: item_a_2,
        account_id: "shared_brex_acc_1",
        name: "Checking",
        currency: "USD",
        current_balance: 5000
      )
    end
  end

  test "same account_id cannot appear twice under the same brex_item" do
    BrexAccount.create!(
      brex_item: @item_a,
      account_id: "duplicate_acc",
      name: "Checking",
      currency: "USD",
      current_balance: 1000
    )

    duplicate = BrexAccount.new(
      brex_item: @item_a,
      account_id: "duplicate_acc",
      name: "Checking",
      currency: "USD",
      current_balance: 1000
    )
    refute duplicate.valid?
    assert_includes duplicate.errors[:account_id], "has already been taken"

    assert_raises(ActiveRecord::RecordInvalid) do
      BrexAccount.create!(
        brex_item: @item_a,
        account_id: "duplicate_acc",
        name: "Checking",
        currency: "USD",
        current_balance: 1000
      )
    end
  end

  test "minor-unit money converts to decimal account balances" do
    brex_account = @item_a.brex_accounts.create!(
      account_id: "cash_1",
      name: "Operating",
      currency: "USD",
      account_kind: "cash"
    )

    brex_account.upsert_brex_snapshot!(
      {
        id: "cash_1",
        name: "Operating",
        account_kind: "cash",
        current_balance: { amount: 123_456, currency: "USD" },
        available_balance: { amount: 120_000, currency: "USD" }
      }
    )

    assert_equal BigDecimal("1234.56"), brex_account.current_balance
    assert_equal BigDecimal("1200.0"), brex_account.available_balance
  end

  test "invalid Brex money amount falls back to zero" do
    assert_equal BigDecimal("0"), BrexAccount.money_to_decimal(amount: "not-a-number", currency: "USD")
  end

  test "snapshot sanitizes full account and routing numbers" do
    brex_account = @item_a.brex_accounts.create!(
      account_id: "cash_2",
      name: "Operating",
      currency: "USD",
      account_kind: "cash"
    )

    brex_account.upsert_brex_snapshot!(
      {
        id: "cash_2",
        name: "Operating",
        account_kind: "cash",
        current_balance: { amount: 100, currency: "USD" },
        account_number: "account-last4-9012",
        routing_number: "routing-last4-0021",
        token: "test-token-placeholder"
      }
    )

    payload = brex_account.raw_payload
    refute_includes payload.values.compact.map(&:to_s).join(" "), "account-last4-9012"
    refute_includes payload.values.compact.map(&:to_s).join(" "), "routing-last4-0021"
    assert_equal "9012", payload["account_number_last4"]
    assert_equal "0021", payload["routing_number_last4"]
    assert_equal "[FILTERED]", payload["token"]
  end

  test "transaction payload sanitizer drops arbitrary card metadata" do
    sanitized = BrexAccount.sanitize_payload(
      {
        id: "tx_1",
        card_metadata: {
          card_id: "card_1",
          pan: "test-pan-placeholder",
          private_note: "private",
          last_four: "card ending 1111"
        }
      }
    )

    assert_equal({ "card_id" => "card_1", "last_four" => "1111" }, sanitized["card_metadata"])
    refute_includes sanitized.to_s, "test-pan-placeholder"
    refute_includes sanitized.to_s, "private"
  end

  test "transaction payload sanitizer limits card metadata last four to digits" do
    sanitized = BrexAccount.sanitize_payload(card_metadata: { card_last_four: "card id abc9876" })

    assert_equal "9876", sanitized["card_metadata"]["last_four"]
    refute_includes sanitized.to_s, "abc9876"
  end

  test "linked_account uses the cached account association" do
    brex_account = @item_a.brex_accounts.create!(
      account_id: "cash_linked_alias",
      name: "Linked Alias",
      currency: "USD",
      account_kind: "cash"
    )
    account = @family_a.accounts.create!(
      name: "Linked Alias",
      balance: 0,
      currency: "USD",
      accountable: Depository.new
    )
    AccountProvider.create!(account: account, provider: brex_account)

    assert_equal brex_account.account, brex_account.linked_account
  end
end
