# frozen_string_literal: true

require "test_helper"

class KrakenItemTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @item = KrakenItem.create!(
      family: @family,
      name: "My Kraken",
      api_key: "test_key",
      api_secret: "test_secret"
    )
  end

  test "belongs to family" do
    assert_equal @family, @item.family
  end

  test "has good status by default" do
    assert_equal "good", @item.status
  end

  test "strips credential whitespace before validation" do
    item = KrakenItem.create!(
      family: @family,
      name: "Whitespace Kraken",
      api_key: " key \n",
      api_secret: " secret \n"
    )

    assert_equal "key", item.api_key
    assert_equal "secret", item.api_secret
  end

  test "rejects whitespace-only credentials" do
    item = KrakenItem.new(family: @family, name: "Blank Kraken", api_key: "   ", api_secret: "\n")

    assert_not item.valid?
    assert_includes item.errors[:api_key], "can't be blank"
    assert_includes item.errors[:api_secret], "can't be blank"
  end

  test "credentials_configured rejects whitespace-only values" do
    @item.update_columns(api_key: "   ", api_secret: "secret")

    assert_not @item.reload.credentials_configured?
  end

  test "next_nonce is monotonic even when stored nonce is ahead of clock" do
    @item.update!(last_nonce: 9_000_000_000_000_000_000)

    first = @item.next_nonce!.to_i
    second = @item.next_nonce!.to_i

    assert_equal 9_000_000_000_000_000_001, first
    assert_equal 9_000_000_000_000_000_002, second
    assert_equal second, @item.reload.last_nonce
  end

  test "kraken provider uses item nonce generator" do
    @item.update!(last_nonce: 9_000_000_000_000_000_000)
    provider = @item.kraken_provider

    nonce = provider.send(:nonce_generator).call

    assert_equal "9000000000000000001", nonce
    assert_equal 9_000_000_000_000_000_001, @item.reload.last_nonce
  end

  test "duplicate combined account ids are scoped by kraken item" do
    other_item = KrakenItem.create!(
      family: @family,
      name: "Other Kraken",
      api_key: "other_key",
      api_secret: "other_secret"
    )

    @item.kraken_accounts.create!(name: "Main", account_id: "combined", account_type: "combined", currency: "USD")
    other_account = other_item.kraken_accounts.create!(name: "Other", account_id: "combined", account_type: "combined", currency: "USD")

    assert other_account.persisted?
  end

  test "encrypts credentials when active record encryption is configured" do
    skip "Encryption not configured" unless KrakenItem.encryption_ready?

    item = KrakenItem.create!(
      family: @family,
      name: "Encrypted Kraken",
      api_key: "encrypted_key",
      api_secret: "encrypted_secret"
    )

    quoted_id = KrakenItem.connection.quote(item.id)
    raw = KrakenItem.connection.select_one("SELECT api_key, api_secret FROM kraken_items WHERE id = #{quoted_id}")
    assert_not_equal "encrypted_key", raw["api_key"]
    assert_not_equal "encrypted_secret", raw["api_secret"]
  end
end
