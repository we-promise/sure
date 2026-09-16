require "test_helper"
require "timeout"
require_relative "../../support/provider_ingestion_test_helper"

class SophtronItem::LifecycleTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include ProviderIngestionTestHelper
  self.use_transactional_tests = false

  Fence = Provider::AccountData::LegacyWriterFence

  test "quiescing and native ownership reject every lifecycle command before HTTP writes or scheduling" do
    with_item do |item|
      source = item.upsert_sophtron_account(account_data)
      financial = create_account(item.family)
      AccountProvider.create!(account: financial, provider: source)
      control = ProviderMigrationControl.create!(family: item.family, provider_key: "sophtron",
        legacy_type: "SophtronItem", legacy_id: item.id, state: "quiescing")
      command = SophtronItem::Lifecycle.new(item)
      SophtronItem.any_instance.expects(:sophtron_provider).never
      before = item.reload.attributes

      %w[quiescing active retired].each do |state|
        control.update!(state: state)
        assert_no_enqueued_jobs do
          assert_no_difference [ "SophtronItem.count", "SophtronAccount.count", "Account.count", "AccountProvider.count" ] do
            assert_raises(Fence::OwnershipChanged) { command.connect_institution(**connection_parameters) }
            assert_raises(Fence::OwnershipChanged) { command.link_accounts(account_ids: [ source.account_id ], account_type: "Depository") }
            assert_raises(Fence::OwnershipChanged) { command.link_existing_account(account_id: financial.id, sophtron_account_id: source.account_id) }
            assert_raises(Fence::OwnershipChanged) { command.complete_account_setup(account_types: { source.id => "Depository" }, account_subtypes: {}) }
            assert_raises(Fence::OwnershipChanged) { command.toggle_manual_sync }
            assert_raises(Fence::OwnershipChanged) { command.disconnect }
            assert_raises(Fence::OwnershipChanged) { item.unlink_all!(dry_run: true) }
            assert_raises(Fence::OwnershipChanged) { item.unlink_all! }
            assert_raises(Fence::OwnershipChanged) { item.destroy_later }
            assert_raises(Fence::OwnershipChanged) { item.destroy! }
            assert_raises(Fence::OwnershipChanged) { source.destroy! }
          end
        end
        assert_equal before, item.reload.attributes
      end
    end
  end

  test "new links retain admission from fresh discovery through initial scheduling" do
    with_item do |item|
      SophtronItem.find(item.id).update!(user_id: "fresh-user", access_key: "fresh-key", user_institution_id: "fresh-institution")
      provider = mock("fresh lifecycle client")
      Provider::Sophtron.expects(:new).with("fresh-user", "fresh-key", base_url: Provider::Sophtron::DEFAULT_BASE_URL).returns(provider)
      provider.expects(:get_accounts).with do |institution|
        assert_equal "fresh-institution", institution
        assert_request_permit(item)
        true
      end.returns({ accounts: [ account_data ] })
      SophtronItem.any_instance.expects(:start_initial_load_later).with do
        assert_request_permit(item)
        assert item.sophtron_accounts.find_by!(account_id: "remote").account_provider.present?
        true
      end

      result = SophtronItem::Lifecycle.new(item).link_accounts(account_ids: [ "remote", "remote", "unknown" ], account_type: "Depository")
      financial = result[:created_accounts].sole
      @financial_ids << financial.id
      assert_equal item.family_id, financial.family_id
      assert_equal 0, financial.balance
      assert_equal [ "Checking" ], result[:already_linked_accounts]
      assert_empty result[:invalid_accounts]
      assert_equal :drained, try_drain(item)
    end
  end

  test "existing account selection rejects another family before any provider request" do
    with_item do |item|
      foreign = create_account(families(:empty))
      SophtronItem.any_instance.expects(:sophtron_provider).never
      assert_raises(ActiveRecord::RecordNotFound) do
        SophtronItem::Lifecycle.new(item).link_existing_account(account_id: foreign.id, sophtron_account_id: "remote")
      end
      assert_empty foreign.account_providers
      assert_empty item.sophtron_accounts
    end
  end

  test "existing link selection is rechecked after HTTP before linking" do
    with_item do |item|
      selected = create_account(item.family)
      replacement = create_account(item.family)
      source = item.upsert_sophtron_account(account_data)
      provider = mock("link race client")
      SophtronItem.any_instance.stubs(:sophtron_provider).returns(provider)
      provider.expects(:get_accounts).with do
        AccountProvider.create!(account: replacement, provider: source)
        true
      end.returns({ accounts: [ account_data ] })
      SophtronItem.any_instance.expects(:start_initial_load_later).never

      result = SophtronItem::Lifecycle.new(item).link_existing_account(account_id: selected.id, sophtron_account_id: "remote")
      assert_equal :sophtron_account_already_linked, result[:error]
      assert_empty selected.account_providers
      assert_equal replacement.id, source.reload.account_provider.account_id
    end
  end

  test "setup preserves snapshot balance subtype and skips while limiting source IDs to the admitted item" do
    with_item do |item|
      selected = item.upsert_sophtron_account(account_data)
      skipped = item.upsert_sophtron_account(account_data.merge(account_id: "skipped"))
      foreign = new_item(families(:empty)).upsert_sophtron_account(account_data)
      SophtronItem.any_instance.expects(:sophtron_provider).never
      SophtronItem.any_instance.expects(:start_initial_load_later).with { assert_request_permit(item); true }

      result = SophtronItem::Lifecycle.new(item).complete_account_setup(account_types: {
        selected.id => "Depository", skipped.id => "skip", foreign.id => "Depository"
      }, account_subtypes: { selected.id => "savings" })
      financial = result[:created_accounts].sole
      @financial_ids << financial.id
      assert_equal BigDecimal("123.45"), financial.balance
      assert_equal "savings", financial.accountable.subtype
      assert_equal 1, result[:skipped_count]
      assert_nil skipped.reload.account_provider
      assert_nil foreign.reload.account_provider
    end
  end

  test "additional institution remains unsaved through HTTP and keeps original identity intact" do
    with_item do |item|
      SophtronItem.find(item.id).update!(user_id: "fresh-user", access_key: "fresh-key", customer_id: "fresh-customer")
      provider = mock("institution client")
      SophtronItem.any_instance.stubs(:sophtron_provider).returns(provider)
      before_ids = SophtronItem.ids
      provider.expects(:create_user_institution).with do |**attributes|
        assert_equal connection_parameters.except(:institution_name, :new_institution).merge(pin: ""), attributes
        assert_request_permit(item)
        assert_equal before_ids.sort, SophtronItem.ids.sort
        true
      end.returns({ JobID: "new-job", UserInstitutionID: "new-institution" })

      target = SophtronItem::Lifecycle.new(item).connect_institution(**connection_parameters)
      @item_ids << target.id
      assert_not_equal item.id, target.id
      assert_equal "original-institution", item.reload.user_institution_id
      assert_equal [ item.family_id, "fresh-user", "fresh-key", "fresh-customer", "new-institution", "new-job" ],
        target.attributes.values_at("family_id", "user_id", "access_key", "customer_id", "user_institution_id", "current_job_id")
      assert_equal :drained, try_drain(item)
    end
  end

  test "failed or incomplete institution creation never leaves an empty cloned item" do
    with_item do |item|
      provider = mock("failed institution client")
      SophtronItem.any_instance.stubs(:sophtron_provider).returns(provider)
      provider.expects(:create_user_institution).raises(Provider::Sophtron::Error.new("secret upstream payload", :bad_request))
      assert_no_difference "SophtronItem.count" do
        assert_raises(Provider::Sophtron::Error) { SophtronItem::Lifecycle.new(item).connect_institution(**connection_parameters) }
      end
      provider.expects(:create_user_institution).returns({ JobID: "incomplete" })
      assert_no_difference "SophtronItem.count" do
        assert_raises(Provider::Sophtron::Error) { SophtronItem::Lifecycle.new(item).connect_institution(**connection_parameters) }
      end
      assert_equal "original-institution", item.reload.user_institution_id
      assert_nil item.current_job_id
    end
  end

  test "credential customer or institution changes during HTTP prevent stale response publication" do
    with_item do |item|
      provider = mock("stale institution client")
      SophtronItem.any_instance.stubs(:sophtron_provider).returns(provider)
      %i[access_key customer_id user_institution_id].each do |field|
        provider.expects(:create_user_institution).with do
          SophtronItem.find(item.id).update!(field => SecureRandom.uuid)
          true
        end.returns({ JobID: "stale-job", UserInstitutionID: "stale-institution" })
        assert_no_difference "SophtronItem.count" do
          assert_raises(Fence::OwnershipChanged) { SophtronItem::Lifecycle.new(item).connect_institution(**connection_parameters) }
        end
        assert_nil item.reload.current_job_id
      end
    end
  end

  test "unlink preview and execution preserve financial rows and holding IDs" do
    with_item do |item|
      source = item.upsert_sophtron_account(account_data)
      financial = create_account(item.family)
      link = AccountProvider.create!(account: financial, provider: source)
      holding = financial.holdings.create!(account_provider: link, security: securities(:aapl),
        date: Date.current, qty: 1, price: 10, amount: 10, currency: "USD")

      preview = item.unlink_all!(dry_run: true).sole
      assert_equal [ link.id ], preview[:provider_link_ids]
      assert_equal link.id, holding.reload.account_provider_id
      result = item.unlink_all!.sole
      assert_equal preview, result
      assert_nil holding.reload.account_provider_id
      assert Account.exists?(financial.id)
      assert SophtronAccount.exists?(source.id)
      assert_equal [], item.unlink_all!.sole[:provider_link_ids]
    end
  end

  test "unlink rejects a foreign source and a cross-family financial link without removing either" do
    with_item do |item|
      other = new_item(families(:empty))
      foreign_source = other.upsert_sophtron_account(account_data)
      assert_raises(Fence::OwnershipChanged) { item.unlink_account!(foreign_source) }
      source = item.upsert_sophtron_account(account_data)
      foreign_account = create_account(other.family)
      link = AccountProvider.create!(account: foreign_account, provider: source)
      assert_raises(Fence::OwnershipChanged) { item.unlink_all! }
      assert AccountProvider.exists?(link.id)
    end
  end

  test "partial unlink failure prevents scheduling deletion and records no exception payload" do
    with_item do |item|
      source = item.upsert_sophtron_account(account_data)
      financial = create_account(item.family)
      link = AccountProvider.create!(account: financial, provider: source)
      AccountProvider.any_instance.expects(:destroy!).raises(ActiveRecord::RecordNotDestroyed, "secret payload")
      DebugLogEntry.expects(:capture).with do |attributes|
        attributes[:metadata] == { item_id: item.id, sophtron_account_id: source.id, error_class: "ActiveRecord::RecordNotDestroyed" } &&
          !attributes.to_s.include?("secret payload")
      end
      assert_no_enqueued_jobs do
        result = SophtronItem::Lifecycle.new(item).disconnect
        assert_equal "ActiveRecord::RecordNotDestroyed", result.sole[:error]
      end
      assert AccountProvider.exists?(link.id)
      assert_not item.reload.scheduled_for_deletion?
    ensure
      AccountProvider.any_instance.unstub(:destroy!)
    end
  end

  test "direct source and item destruction retain accounts while removing only admitted sources" do
    with_item do |item|
      source = item.upsert_sophtron_account(account_data)
      financial = create_account(item.family)
      AccountProvider.create!(account: financial, provider: source)
      source.destroy!
      assert Account.exists?(financial.id)
      assert_empty financial.reload.account_providers
      other_source = item.upsert_sophtron_account(account_data.merge(account_id: "other"))
      item.destroy!
      assert_not SophtronAccount.exists?(other_source.id)
      assert Account.exists?(financial.id)
    end
  end

  test "an initial unlink query failure survives even if diagnostics also fail" do
    with_item do |item|
      source = item.upsert_sophtron_account(account_data)
      failed_scope = mock("failed link lookup")
      failed_scope.expects(:order).with(:id).returns(failed_scope)
      failed_scope.expects(:pluck).with(:id, :account_id).raises(ActiveRecord::StatementInvalid, "database details")
      AccountProvider.expects(:where).with(provider_type: "SophtronAccount", provider_id: source.id).returns(failed_scope)
      DebugLogEntry.expects(:capture).raises(StandardError, "diagnostic unavailable")

      result = item.unlink_account!(source)
      assert_equal source.id, result[:sfa_id]
      assert_equal [], result[:provider_link_ids]
      assert_equal "ActiveRecord::StatementInvalid", result[:error]
      assert_not result.to_s.include?("database details")
    ensure
      AccountProvider.unstub(:where)
      DebugLogEntry.unstub(:capture)
    end
  end

  test "dependent destruction refuses a link that reappeared after the parent detached accounts" do
    with_item do |item|
      source = item.upsert_sophtron_account(account_data)
      financial = create_account(item.family)
      link = AccountProvider.create!(account: financial, provider: source)
      source.destroyed_by_association = SophtronItem.reflect_on_association(:sophtron_accounts)

      assert_raises(Fence::OwnershipChanged) { source.destroy! }
      assert SophtronAccount.exists?(source.id)
      assert AccountProvider.exists?(link.id)
      assert Account.exists?(financial.id)
    end
  end

  test "disconnect holds admission through deletion scheduling and preserves local accounts" do
    with_item do |item|
      source = item.upsert_sophtron_account(account_data)
      financial = create_account(item.family)
      AccountProvider.create!(account: financial, provider: source)
      DestroyJob.expects(:perform_later).with do |current|
        assert_equal item.id, current.id
        assert current.scheduled_for_deletion?
        assert_request_permit(item)
        true
      end

      assert_nil SophtronItem::Lifecycle.new(item).disconnect.sole[:error]
      assert item.reload.scheduled_for_deletion?
      assert_empty financial.reload.account_providers
      assert Account.exists?(financial.id)
      assert_equal :drained, try_drain(item)
    end
  end

  test "manual mode only changes the selected institution using current item policy" do
    with_item do |item|
      selected = item.upsert_sophtron_account(account_data.merge(user_institution_id: "chosen"))
      other = item.upsert_sophtron_account(account_data.merge(account_id: "other", user_institution_id: "other"))
      SophtronItem.find(item.id).update!(manual_sync: true)
      result = SophtronItem::Lifecycle.new(item).toggle_manual_sync(institution_key: "chosen")
      assert_equal false, result[:enabled]
      assert_not item.reload.manual_sync?
      assert_not selected.reload.manual_sync?
      assert other.reload.manual_sync?
    end
  end

  private
    def account_data
      { account_id: "remote", account_name: "Checking", balance: "123.45", currency: "USD" }.with_indifferent_access
    end

    def connection_parameters
      { institution_id: "new", institution_name: "New bank", username: "bank-user", password: "bank-secret", new_institution: true }
    end

    def create_account(family)
      Account.create!(family: family, name: "Lifecycle account", currency: "USD", balance: 0, accountable: Depository.new).tap do |account|
        @financial_ids << account.id
      end
    end

    def new_item(family)
      SophtronItem.create!(family: family, name: "Lifecycle source", user_id: "developer-user",
        access_key: Base64.strict_encode64("test-key"), customer_id: "customer", user_institution_id: "original-institution").tap do |item|
        @item_ids << item.id
      end
    end

    def with_item
      @item_ids, @financial_ids = [], []
      with_provider_encryption do
        yield new_item(families(:dylan_family))
      ensure
        ProviderMigrationControl.where(legacy_type: "SophtronItem", legacy_id: @item_ids).destroy_all
        Account.where(id: @financial_ids).destroy_all
        SophtronItem.where(id: @item_ids).each(&:destroy!)
      end
    end

    def assert_request_permit(item)
      assert_equal 0, ApplicationRecord.connection.open_transactions
      assert_equal :busy, try_drain(item)
    end

    def try_drain(item)
      skip "Requires two database sessions" if ApplicationRecord.connection_pool.size < 2
      worker = Thread.new do
        Fence.with_exclusive(item) { :drained }
      rescue Fence::Busy
        :busy
      end
      Timeout.timeout(5) { worker.value }
    ensure
      worker&.kill if worker&.alive?
      worker&.join
    end
end
