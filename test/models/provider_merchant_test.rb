require "test_helper"

class ProviderMerchantTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    @provider_merchant = ProviderMerchant.create!(name: "Acme Synced", source: "plaid")
  end

  # Regression: issue #1977. Converting a synced merchant to a family merchant
  # reassigns merchant_id via update_all; the entries must be flagged so the
  # next provider sync doesn't revert the conversion.
  test "convert_to_family_merchant_for flags reassigned transactions as user_modified" do
    entry = create_transaction(merchant: @provider_merchant)
    assert_not entry.user_modified?

    family_merchant = @provider_merchant.convert_to_family_merchant_for(@family)

    entry.reload
    assert_equal family_merchant.id, entry.entryable.merchant_id
    assert entry.user_modified?, "converted transaction's entry must be flagged so provider sync won't revert it"
  end

  # Regression: issue #1977. Unlinking a synced merchant nulls merchant_id;
  # without the flag the next sync re-links it.
  test "unlink_from_family flags affected transactions as user_modified" do
    entry = create_transaction(merchant: @provider_merchant)
    assert_not entry.user_modified?

    @provider_merchant.unlink_from_family(@family)

    entry.reload
    assert_nil entry.entryable.merchant_id
    assert entry.user_modified?, "unlinked transaction's entry must be flagged so provider sync won't re-link it"
  end

  test "find_by_import_data prefers provider_merchant_id over name, scoped to source" do
    by_id = ProviderMerchant.create!(name: "Renamed Upstream", source: "plaid", provider_merchant_id: "plaid_acme")
    ProviderMerchant.create!(name: "Acme", source: "lunchflow")

    found = ProviderMerchant.find_by_import_data({ "name" => "Old Name", "provider_merchant_id" => "plaid_acme" }, "plaid")

    assert_equal by_id, found
    assert_equal @provider_merchant, ProviderMerchant.find_by_import_data({ "name" => "Acme Synced" }, "plaid")
    assert_nil ProviderMerchant.find_by_import_data({ "name" => "Acme Synced" }, "lunchflow")
  end

  test "import_diff reports only non-blank website_url and name differences" do
    merchant = ProviderMerchant.create!(name: "Acme", source: "plaid", provider_merchant_id: "plaid_acme", website_url: "https://acme.com")

    assert_empty merchant.import_diff({ "name" => "Acme", "website_url" => "https://acme.com", "color" => "#123456" })
    assert_empty merchant.import_diff({ "name" => "Acme", "website_url" => "" })

    assert_equal(
      [ { field: "website_url", imported_value: "https://acme.io", kept_value: "https://acme.com" },
        { field: "name", imported_value: "Acme Inc", kept_value: "Acme" } ],
      merchant.import_diff({ "name" => "Acme Inc", "website_url" => "https://acme.io" })
    )
  end
end
