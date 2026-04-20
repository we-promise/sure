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

  test "effective_base_url returns custom url when set" do
    assert_equal "https://api-sandbox.mercury.com/api/v1", @mercury_item.effective_base_url
  end

  test "effective_base_url returns default when base_url blank" do
    @mercury_item.base_url = nil
    assert_equal "https://api.mercury.com/api/v1", @mercury_item.effective_base_url
  end

  test "effective_base_url rejects unknown base_url and falls back to default (F-08 SSRF)" do
    @mercury_item.base_url = "http://169.254.169.254/latest/meta-data"
    Rails.logger.expects(:warn).with(regexp_matches(/\[SECURITY\] Rejected MercuryItem base_url/))
    assert_equal MercuryItem::ALLOWED_BASE_URLS.first, @mercury_item.effective_base_url
  end

  test "effective_base_url allows sandbox URL (F-08 SSRF allowlist)" do
    @mercury_item.base_url = "https://api-sandbox.mercury.com/api/v1"
    assert_equal "https://api-sandbox.mercury.com/api/v1", @mercury_item.effective_base_url
  end

  test "validates base_url against the allowlist at save time (F-08)" do
    @mercury_item.base_url = "http://169.254.169.254/"
    assert_not @mercury_item.valid?, "invalid base_url should fail AR validation"
    assert_includes @mercury_item.errors[:base_url], "is not included in the list"
  end

  test "allows blank base_url to fall back to the default at read time" do
    @mercury_item.base_url = nil
    assert @mercury_item.valid?
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

  test "syncer returns MercuryItem::Syncer instance" do
    syncer = @mercury_item.send(:syncer)
    assert_instance_of MercuryItem::Syncer, syncer
  end
end
