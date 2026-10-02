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

  test "convert_to_family_merchant_for carries over the existing iban when not overridden" do
    @provider_merchant.update!(iban: "DE89370400440532013000") # pipelock:ignore IBAN

    family_merchant = @provider_merchant.convert_to_family_merchant_for(@family)

    assert_equal "DE89370400440532013000", family_merchant.iban # pipelock:ignore IBAN
  end

  test "convert_to_family_merchant_for uses the submitted iban override" do
    @provider_merchant.update!(iban: "DE89370400440532013000") # pipelock:ignore IBAN

    family_merchant = @provider_merchant.convert_to_family_merchant_for(@family, iban: "AT611904300234573201") # pipelock:ignore IBAN

    assert_equal "AT611904300234573201", family_merchant.iban # pipelock:ignore IBAN
  end

  test "convert_to_family_merchant_for preserves an explicitly cleared iban" do
    @provider_merchant.update!(iban: "DE89370400440532013000") # pipelock:ignore IBAN

    family_merchant = @provider_merchant.convert_to_family_merchant_for(@family, iban: "")

    assert_nil family_merchant.iban
  end

  test "convert_to_family_merchant_for preserves an explicitly cleared website_url" do
    @provider_merchant.update!(website_url: "https://example.com")

    family_merchant = @provider_merchant.convert_to_family_merchant_for(@family, website_url: "")

    assert_nil family_merchant.website_url
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

  test "import_diff flags a non-blank provider_merchant_id that differs from, or is missing on, the existing merchant" do
    with_id = ProviderMerchant.create!(name: "Acme", source: "lunchflow", provider_merchant_id: "id-1")
    without_id = ProviderMerchant.create!(name: "Acme", source: "akahu")

    assert_equal(
      [ { field: "provider_merchant_id", imported_value: "id-2", kept_value: "id-1" } ],
      with_id.import_diff({ "name" => "Acme", "provider_merchant_id" => "id-2" })
    )
    assert_empty with_id.import_diff({ "name" => "Acme", "provider_merchant_id" => "id-1" })
    assert_equal(
      [ { field: "provider_merchant_id", imported_value: "id-2", kept_value: nil } ],
      without_id.import_diff({ "name" => "Acme", "provider_merchant_id" => "id-2" })
    )
    assert_empty without_id.import_diff({ "name" => "Acme" })
  end

  test "does not support color: writes are discarded and the stored value is NULL" do
    assert_nil ProviderMerchant.new(name: "New", source: "plaid", color: "#123456").color

    created = ProviderMerchant.create!(name: "Colored", source: "plaid", color: "#123456")

    assert_nil created.color
    assert_nil ProviderMerchant.where(id: created.id).pick(:color)
  end

  test "does not support color: a stale value on an old row is never read and is cleared on the next save" do
    legacy = ProviderMerchant.create!(name: "Legacy", source: "plaid")
    legacy.update_column(:color, "#654321")

    assert_nil ProviderMerchant.find(legacy.id).color, "a stale value must not reach a view"
    assert_equal "#654321", ProviderMerchant.where(id: legacy.id).pick(:color), "still stored until the row is saved"

    ProviderMerchant.find(legacy.id).update!(website_url: "https://legacy.example")

    assert_nil ProviderMerchant.where(id: legacy.id).pick(:color)
    assert_equal "https://legacy.example", legacy.reload.website_url
  end

  test "family merchants are unaffected and converting a provider merchant still gives the copy a color" do
    assert_match(/\A#[0-9A-Fa-f]{6}\z/, @family.merchants.create!(name: "Mine").color)

    converted = @provider_merchant.convert_to_family_merchant_for(@family, name: "Acme Mine", color: "#4da568")

    assert_equal "#4da568", converted.color
    assert_nil @provider_merchant.reload.color
  end
end
