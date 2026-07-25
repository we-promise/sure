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

  test "ignored accounts are excluded from setup counts" do
    account = redbark_accounts(:savings_account)
    assert_equal 1, @redbark_item.unlinked_accounts_count

    account.update!(ignored: true)

    fresh_item = RedbarkItem.find(@redbark_item.id)
    assert_equal 0, fresh_item.unlinked_accounts_count
    assert_equal 1, fresh_item.total_accounts_count
    assert_not RedbarkAccount.needs_setup.exists?(id: account.id)
  end

  test "encrypted jsonb payloads round-trip nested structures" do
    payload = {
      "accounts" => [
        { "id" => "acc_1", "name" => "Everyday", "balances" => { "current" => "1024.55", "currency" => "AUD" } },
        { "id" => "acc_2", "name" => "Savings", "meta" => { "tags" => [ "a", "b" ], "nested" => { "deep" => true } } }
      ],
      "fetched_at" => "2026-07-25T00:00:00Z"
    }
    institution = { "name" => "Test Bank", "logo" => "https://example.com/logo.png" }

    @redbark_item.update!(raw_payload: payload, raw_institution_payload: institution)
    reloaded = RedbarkItem.find(@redbark_item.id)

    assert_equal payload, reloaded.raw_payload
    assert_equal institution, reloaded.raw_institution_payload
  end
end
