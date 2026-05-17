require "test_helper"

class BrexItemTest < ActiveSupport::TestCase
  def setup
    @brex_item = brex_items(:one)
  end

  test "fixture is valid" do
    assert @brex_item.valid?
  end

  test "belongs to family" do
    assert_equal families(:dylan_family), @brex_item.family
  end

  test "credentials_configured returns true when token present" do
    assert @brex_item.credentials_configured?
  end

  test "credentials_configured returns false when token blank" do
    @brex_item.token = nil
    assert_not @brex_item.credentials_configured?
  end

  test "credentials_configured returns false when token is whitespace" do
    @brex_item.token = "   "
    assert_not @brex_item.credentials_configured?
  end

  test "effective_base_url returns custom url when set" do
    assert_equal "https://api-staging.brex.com", @brex_item.effective_base_url
  end

  test "effective_base_url returns default when base_url blank" do
    @brex_item.base_url = nil
    assert_equal "https://api.brex.com", @brex_item.effective_base_url
  end

  test "base_url accepts official Brex API roots" do
    assert BrexItem.new(family: families(:empty), name: "Production", token: "token", base_url: "https://api.brex.com").valid?
    assert BrexItem.new(family: families(:empty), name: "Staging", token: "token", base_url: "https://api-staging.brex.com").valid?
  end

  test "base_url normalizes official URL case and trailing slash" do
    item = BrexItem.create!(
      family: families(:empty),
      name: "Normalized Brex",
      token: "token",
      base_url: " HTTPS://API.BREX.COM/ "
    )

    assert_equal "https://api.brex.com", item.base_url
  end

  test "token is stripped before validation and save" do
    item = BrexItem.create!(
      family: families(:empty),
      name: "Token Normalized Brex",
      token: "  normalized_token  ",
      base_url: "https://api.brex.com"
    )

    assert_equal "normalized_token", item.token
  end

  test "token cannot be blanked on update" do
    original_token = @brex_item.token

    assert_raises(ActiveRecord::RecordInvalid) do
      @brex_item.update!(token: "   ")
    end

    assert_equal original_token, @brex_item.reload.token
    assert_includes @brex_item.errors[:token], "can't be blank"
  end

  test "base_url rejects non-Brex hosts and endpoint paths" do
    [
      "http://api.brex.com",
      "https://evil.example.test",
      "https://localhost",
      "https://127.0.0.1",
      "https://10.0.0.1",
      "https://api.brex.com.evil.example",
      "https://api.brex.com@127.0.0.1",
      "https://api.brex.com:444",
      "https://api.brex.com/v2",
      "https://api.brex.com?debug=true",
      "//api.brex.com"
    ].each do |base_url|
      item = BrexItem.new(family: families(:empty), name: "Invalid Brex", token: "token", base_url: base_url)

      refute item.valid?, "Expected #{base_url.inspect} to be invalid"
      assert_includes item.errors[:base_url], I18n.t("activerecord.errors.models.brex_item.attributes.base_url.official_hosts_only")
    end
  end

  test "brex_provider returns Provider::Brex instance" do
    provider = @brex_item.brex_provider
    assert_instance_of Provider::Brex, provider
    assert_equal @brex_item.token, provider.token
  end

  test "declares Brex token and raw payload as encrypted" do
    skip "Encryption not configured" unless BrexItem.encryption_ready?

    assert_includes BrexItem.encrypted_attributes.map(&:to_s), "token"
    assert_includes BrexItem.encrypted_attributes.map(&:to_s), "raw_payload"
  end

  test "resolve for returns explicit credentialed item scoped to family" do
    resolved = BrexItem.resolve_for(family: @brex_item.family, brex_item_id: " #{@brex_item.id} ")

    assert_equal @brex_item, resolved
  end

  test "resolve for refuses explicit items without usable credentials" do
    item = BrexItem.create!(
      family: @brex_item.family,
      name: "Blank Resolve Brex",
      token: "temporary_token",
      base_url: "https://api.brex.com"
    )
    item.update_column(:token, "   ")

    assert_nil BrexItem.resolve_for(family: @brex_item.family, brex_item_id: item.id)
  end

  test "resolve for does not select one item when multiple credentialed items exist" do
    BrexItem.create!(
      family: @brex_item.family,
      name: "Second Resolve Brex",
      token: "second_resolve_token",
      base_url: "https://api.brex.com"
    )

    assert_nil BrexItem.resolve_for(family: @brex_item.family)
  end

  test "schema requires name and token" do
    columns = BrexItem.columns.index_by(&:name)

    assert_equal false, columns["name"].null
    assert_equal false, columns["token"].null
  end

  test "brex_provider returns nil when credentials not configured" do
    @brex_item.token = nil
    assert_nil @brex_item.brex_provider
  end

  test "brex_provider returns nil when persisted base_url is not allowed" do
    @brex_item.update_column(:base_url, "https://evil.example.test")

    assert_nil @brex_item.reload.brex_provider
  end

  test "family credential check ignores blank and scheduled for deletion items" do
    family = families(:empty)
    blank_item = BrexItem.create!(
      family: family,
      name: "Blank Brex",
      token: "temporary_token",
      base_url: "https://api-staging.brex.com"
    )
    blank_item.update_column(:token, "")

    whitespace_item = BrexItem.create!(
      family: family,
      name: "Whitespace Brex",
      token: "temporary_token",
      base_url: "https://api-staging.brex.com"
    )
    whitespace_item.update_column(:token, "   ")

    deleted_item = BrexItem.create!(
      family: family,
      name: "Deleted Brex",
      token: "deleted_token",
      base_url: "https://api-staging.brex.com",
      scheduled_for_deletion: true
    )

    refute family.has_brex_credentials?

    whitespace_item.update_column(:token, "configured_token")
    assert family.has_brex_credentials?

    whitespace_item.update_column(:token, "   ")
    deleted_item.update!(scheduled_for_deletion: false)
    assert family.has_brex_credentials?
  end

  test "syncer returns BrexItem::Syncer instance" do
    syncer = @brex_item.send(:syncer)
    assert_instance_of BrexItem::Syncer, syncer
  end
end
