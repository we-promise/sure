require "test_helper"
require_relative "../../support/financekit_test_helper"

class Financekit::LifecycleTest < ActiveSupport::TestCase
  include FinancekitTestHelper

  setup { financekit_setup }

  test "another provider cannot attach to a FinanceKit canonical account" do
    assert_raises(ActiveRecord::RecordInvalid) do
      @source.account.account_providers.create!(provider: plaid_accounts(:one))
    end
  end

  test "a provider link pointing at a missing account is invalid rather than raising" do
    provider_link = AccountProvider.new(account_id: SecureRandom.uuid, provider: plaid_accounts(:one))

    assert_not provider_link.valid?
    assert_includes provider_link.errors[:account], "must exist"
  end

  test "a source account cannot link to another family" do
    other = users(:empty)
    account = other.family.accounts.create!(owner: other, name: "Other household", currency: "USD", balance: 25,
      accountable: Depository.new(subtype: "checking"))
    new_source = SecureRandom.uuid
    @item.update!(status: "repair_required", consent: @item.consent.merge(
      "selected_source_account_ids" => [ @source_id, new_source ]))

    assert_raises(ActiveRecord::RecordNotFound) do
      FinancekitAccount.map!(@item, new_source, @mapping_input.except("booked_balance", "observed_at").merge(
        "action" => "link", "account_id" => account.id))
    end
  end

  test "family reset removes publisher source records without touching another family" do
    Provider::Plaid.any_instance.stubs(:remove_item)
    other = users(:empty)
    other.update!(preferences: other.preferences.merge("preview_features_enabled" => true))
    source_id = SecureRandom.uuid
    enrollment = @enrollment.deep_dup
    enrollment["enrollment_id"] = SecureRandom.uuid
    enrollment["consent"]["selected_source_account_ids"] = [ source_id ]
    other_item = Financekit::Enrollment.create!(other, enrollment).item
    accept_and_apply

    Family::FinancialDataReset.new(family: @family, dry_run: false, confirmed: true).call

    assert_not FinancekitItem.exists?(@item.id)
    assert_not FinancekitAccountLineage.where(family: @family).exists?
    assert FinancekitItem.exists?(other_item.id)
  end

  test "disconnect revokes the restricted credential and releases the canonical writer" do
    account = @source.account
    credential = @credential

    @item.disconnect!

    assert_equal "revoked", @item.reload.status
    assert_not @item.authenticate_credential?(credential)
    assert_nil @source.financekit_account_lineage.reload.account_provider
    assert_not account.reload.linked?
  end

  test "replacement enrollment reuses lineage and source identity without duplicating ledger entries" do
    accept_and_apply
    account = @source.account
    entry = account.entries.sole
    lineage = @source.financekit_account_lineage

    replacement_enrollment = @enrollment.deep_dup
    replacement_enrollment["enrollment_id"] = SecureRandom.uuid
    replacement_enrollment["replaces_connection_id"] = @item.id
    replacement = Financekit::Enrollment.create!(@user, replacement_enrollment).item
    replacement_mapping = FinancekitAccount.map!(replacement, @source_id,
      @mapping_input.except("booked_balance", "observed_at").merge(
        "action" => "link", "account_id" => account.id, "lineage_id" => lineage.id))
    replacement.activate!
    @source = replacement_mapping
    payload = financekit_payload(item: replacement)

    accept_and_apply(payload, item: replacement)

    @item.disconnect!

    assert_equal [ entry.id ], account.entries.reload.pluck(:id)
    assert_equal lineage, FinancekitTransaction.find_by!(source_id: @transaction_id).financekit_account_lineage
    assert_equal "revoked", @item.reload.status
    assert_equal lineage, account.reload.account_providers.sole.provider
    assert_equal @item.generation + 1, replacement.generation
    error = assert_raises(Financekit::Error) do
      @item.update_column(:status, "repair_required")
      @item.repair!
    end
    assert_equal "lineage_writer_conflict", error.code
  end

  test "purging a publisher user releases provider links without another active writer" do
    account = @source.account
    lineage = @source.financekit_account_lineage

    @user.purge

    assert_not FinancekitItem.exists?(@item.id)
    assert_nil lineage.reload.account_provider
    assert_not account.reload.linked?
  end

  test "repair fences accepted work and starts a new generation and stream" do
    queued, = accept_batch
    old_stream = @item.stream_id
    old_credential = @credential

    new_credential = @item.repair!

    assert_equal "revoked", queued.reload.status
    assert_equal "generation_replaced", queued.error_code
    assert_equal 2, @item.reload.generation
    assert_not_equal old_stream, @item.stream_id
    assert_not @item.authenticate_credential?(old_credential)
    assert @item.authenticate_credential?(new_credential)
    assert_equal 1, @item.next_sequence
    assert_nil @item.predecessor_digest
  end

  test "repair requires every selected mapping to still have an account" do
    @source.financekit_account_lineage.update!(account: nil)
    @item.update!(status: "repair_required")

    error = assert_raises(Financekit::Error) { @item.repair! }

    assert_equal "account_setup_required", error.code
    assert_equal "repair_required", @item.reload.status
  end

  test "background publisher is not part of server initiated family sync" do
    assert_empty @family.financekit_items.syncable
    assert_nil @item.last_imported_at
  end
end
