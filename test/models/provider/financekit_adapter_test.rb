require "test_helper"
require_relative "../../support/financekit_test_helper"

class Provider::FinancekitAdapterTest < ActiveSupport::TestCase
  include FinancekitTestHelper

  setup do
    financekit_setup
    @lineage = @source.financekit_account_lineage
    @account = @lineage.account
  end

  teardown { travel_back }

  def adapter
    Provider::FinancekitAdapter.new(@lineage, account: @account)
  end

  def rename_institution(name)
    @source.update_columns(institution_name: name)
  end

  test "institution_name comes from the stored mapping" do
    assert_equal "Apple Wallet", adapter.institution_name
  end

  test "institution_name uses the latest mapping for the lineage" do
    @source.update_columns(created_at: 2.days.ago)
    second_item = Financekit::Enrollment.create!(@user, @enrollment.merge("enrollment_id" => SecureRandom.uuid)).item
    second_item.financekit_accounts.create!(financekit_account_lineage: @lineage, source_id: SecureRandom.uuid,
      mapping_version: 2, mapping_digest: "digest", name: "Test Wallet", institution_name: "Apple",
      currency: "USD", accountable_type: "Depository", subtype: "checking", ledger_timezone: "America/Los_Angeles")

    assert_equal "Apple", adapter.institution_name
  end

  test "institution_name is nil when blank" do
    rename_institution("  ")

    assert_nil adapter.institution_name
    assert_nil adapter.institution_domain
  end

  test "institution_domain is apple.com for Apple and its Wallet products" do
    [ "Apple", "apple", " Apple Inc. ", "Apple Card", "Apple Cash", "Apple Wallet" ].each do |name|
      rename_institution(name)
      assert_equal "apple.com", adapter.institution_domain, "expected apple.com for #{name.inspect}"
    end
  end

  test "institution_domain is not guessed for other institutions" do
    [ "Apple Bank", "Pineapple Credit Union", "Chase", "Goldman Sachs" ].each do |name|
      rename_institution(name)
      assert_nil adapter.institution_domain, "expected no domain for #{name.inspect}"
    end
  end

  test "linked account shows the institution without any column on the account" do
    @account.reload
    assert @account.linked?
    assert_nil @account.read_attribute(:institution_name)

    assert_equal "Apple Wallet", @account.institution_name
    assert_equal "apple.com", @account.institution_domain
  end

  test "a value stored on the account still wins over the provider" do
    @account.update!(institution_name: "My Bank", institution_domain: "https://www.mybank.example/")
    @account.reload
    assert @account.linked?

    assert_equal "My Bank", @account.institution_name
    assert_equal "mybank.example", @account.institution_domain
  end
end
