require "test_helper"
require "timeout"
require_relative "../../support/provider_ingestion_test_helper"

class SophtronItem::DiscoveryTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include ProviderIngestionTestHelper
  self.use_transactional_tests = false

  Fence = Provider::AccountData::LegacyWriterFence

  test "quiescing and native ownership reject public provisioning and discovery before reading cached results" do
    with_item do |item|
      provider = mock("discovery client")
      SophtronItem.any_instance.stubs(:sophtron_provider).returns(provider)
      provider.expects(:get_accounts).once.returns({ accounts: [ account_data ] })
      assert_equal 1, item.fetch_remote_accounts.size
      control = ProviderMigrationControl.create!(family: item.family, provider_key: "sophtron",
        legacy_type: "SophtronItem", legacy_id: item.id, state: "quiescing")
      SophtronItem.any_instance.expects(:sophtron_provider).never
      unparsed = mock("must not normalize")
      unparsed.expects(:with_indifferent_access).never
      before = item.reload.attributes
      %w[quiescing active retired].each do |state|
        control.update!(state: state)
        assert_no_enqueued_jobs do
          assert_no_difference "SophtronAccount.count" do
            assert_raises(Fence::OwnershipChanged) { item.ensure_customer! }
            assert_raises(Fence::OwnershipChanged) { item.verify_and_provision_customer }
            assert_raises(Fence::OwnershipChanged) { item.fetch_remote_accounts }
            assert_raises(Fence::OwnershipChanged) { item.fetch_remote_accounts(force: true) }
            assert_raises(Fence::OwnershipChanged) { item.search_institutions("Bank") }
            assert_raises(Fence::OwnershipChanged) { item.persist_remote_sophtron_accounts([ unparsed ]) }
            assert_raises(Fence::OwnershipChanged) { item.upsert_sophtron_account(unparsed) }
          end
        end
        assert_equal before, item.reload.attributes
      end
    end
  end

  test "verification and provisioning use fresh credentials and hold admission across every request" do
    with_item do |item|
      SophtronItem.find(item.id).update!(user_id: "current-user", access_key: "current-key", base_url: "https://example.com/api")
      provider = mock("admitted credential client")
      Provider::Sophtron.expects(:new).once.with("current-user", "current-key", base_url: "https://example.com/api").returns(provider)
      provider.expects(:health_check_auth).with do
        assert_request_permit(item)
        true
      end.returns({})
      provider.expects(:list_customers).with do
        assert_request_permit(item)
        true
      end.returns([])
      provider.expects(:create_customer).with do |**attributes|
        assert_equal item.generated_customer_unique_id, attributes.fetch(:unique_id)
        assert_request_permit(item)
        true
      end.returns({ CustomerID: "new-customer", CustomerName: "Customer" })

      assert item.verify_and_provision_customer
      assert_equal "new-customer", item.customer_id
      assert_equal "current-user", item.user_id
      assert_equal :drained, try_drain(item)
    end
  end

  test "persisted customer reuse is decided from the admitted source without building a client" do
    with_item do |item|
      SophtronItem.find(item.id).update!(customer_id: "already-provisioned")
      SophtronItem.any_instance.expects(:sophtron_provider).never

      assert_equal "already-provisioned", item.ensure_customer!
      assert_equal "already-provisioned", item.customer_id
    end
  end

  test "empty customer creation response retains the legacy relist fallback" do
    with_item do |item|
      provider = mock("customer client")
      SophtronItem.any_instance.stubs(:sophtron_provider).returns(provider)
      provider.expects(:list_customers).twice.returns([], [ { CustomerID: "created", CustomerName: item.generated_customer_name } ])
      provider.expects(:create_customer).returns({})

      assert_equal "created", item.ensure_customer!
      assert_equal "created", item.reload.customer_id
    end
  end

  test "verification failure retains status behavior and records only sanitized diagnostic context" do
    with_item do |item|
      provider = mock("failed auth")
      SophtronItem.any_instance.stubs(:sophtron_provider).returns(provider)
      provider.expects(:health_check_auth).raises(Provider::Sophtron::Error.new("private-upstream-response", :unauthorized))
      provider.expects(:list_customers).never
      DebugLogEntry.expects(:capture).with do |attributes|
        attributes[:provider_key] == "sophtron" && attributes[:family] == item.family &&
          attributes[:metadata] == { item_id: item.id, error_class: "Provider::Sophtron::Error" } &&
          !attributes.to_s.include?("private-upstream-response")
      end

      assert_not item.verify_and_provision_customer
      assert item.requires_update?
      assert_equal "private-upstream-response", item.last_connection_error
    end
  end

  test "discovery refresh uses admitted institution context and persists before releasing the permit" do
    with_item do |item|
      SophtronItem.find(item.id).update!(user_institution_id: "current-institution")
      provider = mock("account discovery")
      SophtronItem.any_instance.stubs(:sophtron_provider).returns(provider)
      provider.expects(:get_accounts).with do |institution|
        assert_equal "current-institution", institution
        assert_request_permit(item)
        true
      end.returns({ accounts: [ account_data ] })

      assert_equal [ "remote-account" ], item.fetch_remote_accounts(force: true).pluck(:account_id)
      stored = item.sophtron_accounts.sole
      assert_equal "current-institution", stored.institution_metadata.fetch("user_institution_id")
      assert_equal BigDecimal("123.45"), stored.balance
      assert_equal :drained, try_drain(item)
    end
  end

  test "credential and endpoint changes cannot reuse a cached discovery response" do
    with_item do |item|
      provider = mock("cached discovery")
      SophtronItem.any_instance.stubs(:sophtron_provider).returns(provider)
      provider.expects(:get_accounts).with("institution").times(4).returns({ accounts: [ account_data ] })

      item.fetch_remote_accounts
      item.fetch_remote_accounts # Same identity reuses the cache.
      SophtronItem.find(item.id).update_columns(user_id: "replacement-user")
      item.fetch_remote_accounts
      SophtronItem.find(item.id).update_columns(access_key: "replacement-key")
      item.fetch_remote_accounts
      SophtronItem.find(item.id).update_columns(base_url: "https://example.com/api")
      item.fetch_remote_accounts
    end
  end

  test "institution search builds a fresh client and never holds a row transaction across HTTP" do
    with_item do |item|
      SophtronItem.find(item.id).update!(user_id: "current-user")
      provider = mock("institution search")
      Provider::Sophtron.expects(:new).with("current-user", item.access_key, base_url: item.effective_base_url).returns(provider)
      provider.expects(:search_institutions).with do |query|
        assert_equal "Credit Union", query
        assert_request_permit(item)
        true
      end.returns([ { InstitutionID: "bank-id" } ])

      assert_equal [ { InstitutionID: "bank-id" } ], item.search_institutions("Credit Union")
    end
  end

  test "direct discovery snapshot helpers create accounts using fresh item metadata" do
    with_item do |item|
      SophtronItem.find(item.id).update!(institution_name: "Current institution", manual_sync: true)
      source = item.upsert_sophtron_account(account_data)
      assert source.persisted?
      assert source.manual_sync?
      assert_equal "Current institution", source.institution_metadata.fetch("name")

      item.persist_remote_sophtron_accounts([ account_data.merge(account_id: "second-account") ])
      assert_equal 2, item.sophtron_accounts.count
    end
  end

  private
    def account_data
      { account_id: "remote-account", account_name: "Checking", balance: "123.45", currency: "USD" }.with_indifferent_access
    end

    def with_item
      original_cache = Rails.cache
      Rails.cache = ActiveSupport::Cache::MemoryStore.new
      with_provider_encryption do
        item = SophtronItem.create!(family: families(:dylan_family), name: "Credential discovery",
          user_id: "developer-user", access_key: Base64.strict_encode64("test-key"), user_institution_id: "institution")
        yield item
      ensure
        if item&.persisted?
          ProviderMigrationControl.where(legacy_type: "SophtronItem", legacy_id: item.id).destroy_all
          item.reload.destroy!
        end
      end
    ensure
      Rails.cache = original_cache
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
