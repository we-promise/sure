# frozen_string_literal: true

require "test_helper"

class RevolutXItemTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "creating without a private key generates an Ed25519 key" do
    item = @family.revolut_x_items.create!(name: "Revolut X")

    assert OpenSSL::PKey.read(item.private_key).oid == "ED25519"
    assert item.public_key_pem.start_with?("-----BEGIN PUBLIC KEY-----")
    assert_equal OpenSSL::PKey.read(item.private_key).public_to_pem, item.public_key_pem
  end

  test "keeps a supplied Ed25519 key" do
    pem = OpenSSL::PKey.generate_key("ED25519").private_to_pem

    item = @family.revolut_x_items.create!(name: "Revolut X", private_key: pem)

    assert_equal pem, item.private_key
  end

  test "rejects a private key that is not Ed25519" do
    rsa = @family.revolut_x_items.new(name: "Revolut X", private_key: OpenSSL::PKey::RSA.generate(2048).to_pem)
    garbage = @family.revolut_x_items.new(name: "Revolut X", private_key: "not a key")

    assert_not rsa.valid?
    assert rsa.errors.added?(:private_key, :invalid)
    assert_not garbage.valid?
  end

  test "rejects a password-encrypted Ed25519 key without prompting for its passphrase" do
    key = OpenSSL::PKey.generate_key("ED25519")
    encrypted = @family.revolut_x_items.new(name: "Revolut X", private_key: key.private_to_pem(OpenSSL::Cipher.new("aes-256-cbc"), "secret"))
    plain = @family.revolut_x_items.new(name: "Revolut X", private_key: key.private_to_pem)

    assert_not encrypted.valid?
    assert encrypted.errors.added?(:private_key, :invalid)
    assert plain.valid?
  end

  test "a failed import is captured to the debug log and re-raised" do
    item = revolut_x_items(:one)
    provider = mock
    provider.stubs(:get_balances).raises(Provider::RevolutX::ApiError, "boom")
    item.stubs(:revolut_x_provider).returns(provider)

    assert_difference -> { DebugLogEntry.where(provider_key: "revolut_x", level: "error").count }, 1 do
      assert_raises(Provider::RevolutX::ApiError) { item.import_latest_revolut_x_data }
    end

    log = DebugLogEntry.where(provider_key: "revolut_x").order(:created_at).last
    assert_equal "Revolut X import failed: boom", log.message
    assert_equal item.family, log.family
    assert_equal "Provider::RevolutX::ApiError", log.metadata["error_class"]
  end

  test "rejects an Ed25519 public key, which cannot sign" do
    public_pem = OpenSSL::PKey.generate_key("ED25519").public_to_pem
    item = @family.revolut_x_items.new(name: "Revolut X", private_key: public_pem)

    assert_not item.valid?
    assert item.errors.added?(:private_key, :invalid)

    stored = revolut_x_items(:one)
    stored.update_columns(private_key: public_pem)
    assert_not stored.reload.credentials_configured?
  end

  test "an API key must be 64 alphanumerics" do
    item = revolut_x_items(:awaiting_api_key)

    item.api_key = "abc"
    assert_not item.valid?
    assert item.errors.of_kind?(:api_key, :invalid)

    item.api_key = " #{"Ab3" * 21}x \n"
    assert item.valid?
    assert_equal "Ab3" * 21 + "x", item.api_key
  end

  test "credentials are configured only with an API key and a usable private key" do
    assert revolut_x_items(:one).credentials_configured?
    assert_not revolut_x_items(:awaiting_api_key).credentials_configured?

    item = revolut_x_items(:one)
    item.update_columns(private_key: "broken")
    assert_not item.reload.credentials_configured?
  end

  test "an item still waiting for its API key is not syncable" do
    assert_includes RevolutXItem.syncable, revolut_x_items(:one)
    assert_not_includes RevolutXItem.syncable, revolut_x_items(:awaiting_api_key)
  end

  test "builds a provider only when credentials are configured" do
    assert_instance_of Provider::RevolutX, revolut_x_items(:one).revolut_x_provider
    assert_nil revolut_x_items(:awaiting_api_key).revolut_x_provider
  end

  test "classifies fiat by Revolut X asset_type, then by ISO numeric in currencies.yml" do
    item = revolut_x_items(:one)
    item.update!(raw_payload: { "currencies" => {
      "USD" => { "asset_type" => "fiat" },
      "EUR" => { "asset_type" => "fiat" },
      "GBP" => { "asset_type" => "fiat" },
      "BTC" => { "asset_type" => "crypto" }
    } })

    %w[USD eur CZK IDR TRY EGP czk].each { |code| assert item.fiat_currency?(code), "#{code} should be fiat" }
    %w[BTC DOGE USDT SOL].each { |code| assert_not item.fiat_currency?(code), "#{code} should not be fiat" }
  end

  test "Revolut X asset_type wins over currencies.yml" do
    item = revolut_x_items(:one)
    item.update!(raw_payload: { "currencies" => { "CZK" => { "asset_type" => "crypto" } } })

    assert_not item.fiat_currency?("CZK")
  end

  test "sets Revolut X institution defaults" do
    item = revolut_x_items(:awaiting_api_key)

    item.set_revolut_x_institution_defaults!

    assert_equal "Revolut X", item.institution_name
    assert_equal "revolut.com", item.institution_domain
    assert_equal "https://exchange.revolut.com", item.institution_url
    assert_equal "#111827", item.institution_color
  end

  test "unlink_all! removes the account links and detaches holdings" do
    item = revolut_x_items(:one)
    account = accounts(:crypto)
    link = AccountProvider.create!(account: account, provider: revolut_x_accounts(:one))
    holding = account.holdings.create!(
      security: securities(:aapl), date: Date.current, qty: 1, price: 10, amount: 10,
      currency: account.currency, account_provider: link
    )

    item.unlink_all!

    assert_not AccountProvider.exists?(link.id)
    assert_nil holding.reload.account_provider_id
  end
end
