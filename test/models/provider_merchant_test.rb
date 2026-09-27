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

  # Issue #2925: provider merchants that arrive with a website but no logo must
  # get a Brandfetch logo, without replacing a logo the provider supplied.
  test "generates a Brandfetch logo for a website-only merchant" do
    with_brandfetch do
      merchant = ProviderMerchant.create!(name: "Walmart", source: "akahu", website_url: "https://www.walmart.com")

      assert_equal brandfetch_logo("walmart.com"), merchant.logo_url
    end
  end

  test "keeps a provider-supplied logo" do
    with_brandfetch do
      merchant = ProviderMerchant.create!(name: "Walmart", source: "plaid", website_url: "walmart.com", logo_url: "https://plaid.com/walmart.png")

      assert_equal "https://plaid.com/walmart.png", merchant.logo_url
    end
  end

  test "leaves the logo blank without Brandfetch" do
    Setting.stubs(:brand_fetch_client_id).returns(nil)

    merchant = ProviderMerchant.create!(name: "Walmart", source: "akahu", website_url: "walmart.com")

    assert_nil merchant.logo_url
  end

  test "backfill_logos fills website-only merchants in scope and counts them" do
    Setting.stubs(:brand_fetch_client_id).returns(nil) # the websites arrived before Brandfetch was configured
    website_only = ProviderMerchant.create!(name: "Walmart", source: "ai", website_url: "walmart.com")
    out_of_scope = ProviderMerchant.create!(name: "Target", source: "ai", website_url: "target.com")
    with_logo = ProviderMerchant.create!(name: "Costco", source: "plaid", website_url: "costco.com", logo_url: "https://plaid.com/costco.png")

    with_brandfetch do
      scope = ProviderMerchant.where(id: [ website_only.id, with_logo.id, @provider_merchant.id ])

      assert_equal 1, scope.backfill_logos
    end

    assert_equal brandfetch_logo("walmart.com"), website_only.reload.logo_url
    assert_nil out_of_scope.reload.logo_url
    assert_equal "https://plaid.com/costco.png", with_logo.reload.logo_url
    assert_nil @provider_merchant.reload.logo_url
  end

  # Regression: a provider sync can write a real provider logo between the time
  # backfill_logos loads a merchant and when it saves the Brandfetch fallback.
  # The lock-and-recheck must keep the provider logo instead of overwriting it.
  test "backfill_logos does not clobber a logo written concurrently by a provider sync" do
    Setting.stubs(:brand_fetch_client_id).returns(nil) # the website arrived before Brandfetch was configured
    merchant = ProviderMerchant.create!(name: "Walmart", source: "ai", website_url: "walmart.com")

    # find_each yields a freshly loaded instance, not `merchant`, so the stub has
    # to live on the class (restored after) rather than on this one object.
    original_with_lock = ProviderMerchant.instance_method(:with_lock)
    ProviderMerchant.define_method(:with_lock) do |&block|
      if id == merchant.id
        self.class.where(id: id).update_all(logo_url: "https://provider.example.com/walmart.png")
      end
      original_with_lock.bind(self).call(&block)
    end

    with_brandfetch do
      assert_equal 1, ProviderMerchant.where(id: merchant.id).backfill_logos
    end

    assert_equal "https://provider.example.com/walmart.png", merchant.reload.logo_url
  ensure
    ProviderMerchant.define_method(:with_lock, original_with_lock) if original_with_lock
  end

  test "backfill_logos does nothing without Brandfetch" do
    merchant = ProviderMerchant.create!(name: "Walmart", source: "ai", website_url: "walmart.com")
    Setting.stubs(:brand_fetch_client_id).returns(nil)

    assert_equal 0, ProviderMerchant.backfill_logos
    assert_nil merchant.reload.logo_url
  end

  test "family backfill only touches merchants on the family's transactions" do
    Setting.stubs(:brand_fetch_client_id).returns(nil) # the websites arrived before Brandfetch was configured
    assigned = ProviderMerchant.create!(name: "Walmart", source: "ai", website_url: "walmart.com")
    unassigned = ProviderMerchant.create!(name: "Target", source: "ai", website_url: "target.com")
    create_transaction(merchant: assigned)

    with_brandfetch do
      assert_equal 1, @family.backfill_provider_merchant_logos
    end

    assert_equal brandfetch_logo("walmart.com"), assigned.reload.logo_url
    assert_nil unassigned.reload.logo_url
  end

  private
    def with_brandfetch
      Setting.stubs(:brand_fetch_client_id).returns("test_client_id")
      Setting.stubs(:brand_fetch_logo_size).returns(40)
      yield
    ensure
      Setting.unstub(:brand_fetch_client_id)
      Setting.unstub(:brand_fetch_logo_size)
    end

    def brandfetch_logo(domain)
      "https://cdn.brandfetch.io/#{domain}/icon/fallback/lettermark/w/40/h/40?c=test_client_id"
    end
end
