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
end
