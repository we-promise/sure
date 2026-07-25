require "test_helper"

class RedbarkItemTest < ActiveSupport::TestCase
  def setup
    @redbark_item = redbark_items(:one)
  end

  test "fixture is valid" do
    assert @redbark_item.valid?
  end

  test "belongs to family" do
    assert_equal families(:dylan_family), @redbark_item.family
  end

  test "credentials_configured returns true when api_key present" do
    assert @redbark_item.credentials_configured?
  end

  test "credentials_configured returns false when api_key blank" do
    @redbark_item.api_key = nil
    assert_not @redbark_item.credentials_configured?
  end

  test "redbark_provider returns Provider::Redbark instance" do
    provider = @redbark_item.redbark_provider
    assert_instance_of Provider::Redbark, provider
    assert_equal @redbark_item.api_key, provider.api_key
  end

  test "redbark_provider returns nil when credentials not configured" do
    @redbark_item.api_key = nil
    assert_nil @redbark_item.redbark_provider
  end

  test "syncer returns RedbarkItem::Syncer instance" do
    assert_instance_of RedbarkItem::Syncer, @redbark_item.syncer
  end

  test "has_redbark_credentials reflects configured items" do
    assert families(:dylan_family).has_redbark_credentials?
    refute families(:empty).has_redbark_credentials?
  end
end
