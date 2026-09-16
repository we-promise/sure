require "test_helper"
require_relative "../../support/financekit_test_helper"

class Financekit::LifecycleTest < ActiveSupport::TestCase
  include FinancekitTestHelper
  include ActiveJob::TestHelper
  setup { financekit_setup }

  test "another provider cannot attach to a FinanceKit canonical account" do
    assert_raises(ActiveRecord::RecordInvalid) do
      @source.account.account_providers.create!(provider: plaid_accounts(:one))
    end
  end

  test "a source account cannot link to another family" do
    other = users(:empty)
    account = other.family.accounts.create!(owner: other, name: "Other household", currency: "USD", balance: 25,
      accountable: Depository.new(subtype: "checking"))
    new_source = SecureRandom.uuid
    @item.update!(consent: @item.consent.merge("source_ids" => [ @source_id, new_source ]))
    assert_raises(ActiveRecord::RecordNotFound) do
      FinancekitAccount.map!(@item, new_source,
        @mapping_input.except("booked_balance", "observed_at").merge("action" => "link", "account_id" => account.id))
    end
  end

  test "family reset removes source tombstones and import records but no foreign enrollment" do
    Provider::Plaid.any_instance.stubs(:remove_item)
    Financekit::Processor.new(@item).apply!(financekit_payload)
    Family::FinancialDataReset.new(family: @family, dry_run: false, confirmed: true).call
    assert_not FinancekitItem.exists?(@item.id)
    assert_not FinancekitTransaction.where(financekit_account_id: @source.id).exists?
  end

  test "family sync does not manufacture a new Wallet fetch" do
    assert_empty @family.financekit_items.syncable
    assert_nil @item.last_imported_at
  end

  test "foreground import schedules materialization for mapped accounts" do
    assert_enqueued_with(job: SyncJob) do
      Financekit::Processor.new(@item).apply!(financekit_payload)
    end
  end

  test "disconnect releases provider links for remapping" do
    account = @source.account
    @item.disconnect!
    assert_equal "revoked", @item.reload.status
    assert_nil @source.reload.account_provider
    assert_not account.reload.linked?
  end

  test "unmapped retained sources report pending setup" do
    assert_not @item.pending_account_setup?
    @source.account_provider.destroy!
    assert @item.reload.pending_account_setup?
  end

  test "provider reassignment revalidates FinanceKit enrollment family" do
    other = users(:empty)
    other.update!(preferences: other.preferences.merge("preview_features_enabled" => true))
    other_item = Financekit::Enrollment.create!(other, { "enrollment_id" => SecureRandom.uuid, "protocol" => 1,
      "consent" => { "version" => 1, "upload_authorized" => true, "enrichment_acknowledged" => true, "source_ids" => [ SecureRandom.uuid ] } })
    other_source = other_item.financekit_accounts.create!(@source.attributes.except("id", "financekit_item_id", "source_id", "created_at", "updated_at")
      .merge("financekit_item" => other_item, "source_id" => other_item.consent.fetch("source_ids").first))

    link = @source.account_provider
    link.provider = other_source
    assert_not link.valid?
    assert_includes link.errors[:account], "must belong to the FinanceKit enrollment family"
  end
end
