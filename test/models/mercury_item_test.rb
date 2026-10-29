require "test_helper"

class MercuryItemTest < ActiveSupport::TestCase
  def setup
    @mercury_item = mercury_items(:one)
  end

  test "fixture is valid" do
    assert @mercury_item.valid?
  end

  test "belongs to family" do
    assert_equal families(:dylan_family), @mercury_item.family
  end

  test "credentials_configured returns true when token present" do
    assert @mercury_item.credentials_configured?
  end

  test "credentials_configured returns false when token blank" do
    @mercury_item.token = nil
    assert_not @mercury_item.credentials_configured?
  end

  test "credentials_configured returns false when token is whitespace" do
    @mercury_item.token = "   "
    assert_not @mercury_item.credentials_configured?
  end

  test "effective_base_url returns custom url when set" do
    assert_equal "https://api-sandbox.mercury.com/api/v1", @mercury_item.effective_base_url
  end

  test "effective_base_url returns default when base_url blank" do
    @mercury_item.base_url = nil
    assert_equal "https://api.mercury.com/api/v1", @mercury_item.effective_base_url
  end

  test "mercury_provider returns Provider::Mercury instance" do
    provider = @mercury_item.mercury_provider
    assert_instance_of Provider::Mercury, provider
    assert_equal @mercury_item.token, provider.token
  end

  test "mercury_provider returns nil when credentials not configured" do
    @mercury_item.token = nil
    assert_nil @mercury_item.mercury_provider
  end

  test "family credential check ignores blank and scheduled for deletion items" do
    family = families(:empty)
    blank_item = MercuryItem.create!(
      family: family,
      name: "Blank Mercury",
      token: "temporary_token",
      base_url: "https://api-sandbox.mercury.com/api/v1"
    )
    blank_item.update_column(:token, "")

    whitespace_item = MercuryItem.create!(
      family: family,
      name: "Whitespace Mercury",
      token: "temporary_token",
      base_url: "https://api-sandbox.mercury.com/api/v1"
    )
    whitespace_item.update_column(:token, "   ")

    deleted_item = MercuryItem.create!(
      family: family,
      name: "Deleted Mercury",
      token: "deleted_token",
      base_url: "https://api-sandbox.mercury.com/api/v1",
      scheduled_for_deletion: true
    )

    refute family.has_mercury_credentials?

    whitespace_item.update_column(:token, "configured_token")
    assert family.has_mercury_credentials?

    whitespace_item.update_column(:token, "   ")
    deleted_item.update!(scheduled_for_deletion: false)
    assert family.has_mercury_credentials?
  end

  test "syncer returns MercuryItem::Syncer instance" do
    syncer = @mercury_item.send(:syncer)
    assert_instance_of MercuryItem::Syncer, syncer
  end

  # base_url decides where the app sends this connection's credentials, so a
  # value pointing anywhere else is refused at save time and ignored at read
  # time. Both layers matter: rows can be written by console or raw SQL.
  test "refuses a base_url that is not the provider's own host" do
    [
      "https://evil.example.com/api/v1",
      "http://169.254.169.254/",
      "https://localhost/api/v1"
    ].each do |value|
      @mercury_item.base_url = value

      assert_not @mercury_item.valid?, "#{value} must be refused"
      assert_includes @mercury_item.errors.attribute_names, :base_url
    end
  end

  test "a value that slipped past validation is not used" do
    @mercury_item.update_column(:base_url, "https://evil.example.com/api/v1")

    assert_equal Provider::Mercury::DEFAULT_BASE_URL, @mercury_item.reload.effective_base_url
  end

  test "an allowed alternative host is kept" do
    @mercury_item.base_url = "https://api-sandbox.mercury.com/api/v1"

    assert @mercury_item.valid?
    assert_equal "https://api-sandbox.mercury.com/api/v1", @mercury_item.effective_base_url
  end
end
