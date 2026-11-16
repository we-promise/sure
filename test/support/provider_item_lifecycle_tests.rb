# frozen_string_literal: true

# Lifecycle contract for an account provider on the provider kit. Include it in a
# test case that defines `provider_item` (a persisted connection with at least
# one provider account), `other_provider_account` (a provider account that
# belongs to a different account provider in the same family),
# `selectable_accountable_type`, `api_accounts_for(account_ids)` (the
# provider's API payload listing accounts with those ids, each offered for
# that type) and `provider_api_error` (an error the provider's client raises
# for an API failure).
module ProviderItemLifecycleTests
  extend ActiveSupport::Concern

  included do
    test "lifecycle: the connection is a provider item on its own table" do
      assert_kind_of ProviderItem, provider_item
      assert_kind_of ProviderAccount, provider_account
      assert_equal "#{provider_item.provider_key}_items", provider_item.class.table_name
      assert_includes Family::Syncer.syncable_item_associations, :"#{provider_item.provider_key}_items"
    end

    test "lifecycle: a sync runs the shared syncer and records setup counts" do
      provider_item.class.any_instance.stubs(:"import_latest_#{provider_item.provider_key}_data").returns(success: true)
      expected_total = provider_item.provider_accounts.count

      sync = Sync.create!(syncable: provider_item)
      sync.perform

      assert sync.reload.completed?, "expected the sync to complete, was #{sync.status}"
      assert_equal provider_item.class.name, sync.syncable_type
      assert_equal expected_total, sync.sync_stats["total_accounts"]
      assert_equal expected_total, sync.sync_stats["unlinked_accounts"]
    end

    test "lifecycle: unlinking removes the connection's links and detaches their holdings" do
      account, link = link_provider_account(provider_account)
      holding = create_holding(account, link)
      other_account, other_link = link_provider_account(other_provider_account)

      assert_equal provider_account.class.name, link.provider_type

      results = provider_item.unlink_all!

      assert_not AccountProvider.exists?(link.id)
      assert_nil holding.reload.account_provider_id
      assert Account.exists?(account.id)
      assert_includes results.find { |result| result[:provider_account_id] == provider_account.id }[:provider_link_ids], link.id
      assert AccountProvider.exists?(other_link.id), "another provider's link must survive"
      assert_equal other_account, other_link.reload.account
    end

    test "lifecycle: a dry run reports links without removing them" do
      _account, link = link_provider_account(provider_account)

      results = provider_item.unlink_all!(dry_run: true)

      assert AccountProvider.exists?(link.id)
      assert_includes results.find { |result| result[:provider_account_id] == provider_account.id }[:provider_link_ids], link.id
    end

    test "lifecycle: destroying the connection removes its provider accounts and their links" do
      _account, link = link_provider_account(provider_account)
      provider_account_class = provider_item.provider_accounts.klass
      provider_account_ids = provider_item.provider_accounts.ids

      provider_item.destroy!

      assert_not provider_account_class.exists?(id: provider_account_ids)
      assert_not AccountProvider.exists?(link.id)
    end

    test "lifecycle: the account flow is the shared flow and keeps its old constants" do
      assert_operator account_flow_class, :<, ProviderItem::AccountFlow
      assert_same ProviderItem::AccountFlow::NoApiTokenError, account_flow_class::NoApiTokenError
      assert_equal provider_item.class, account_flow_class.item_class
    end

    test "lifecycle: selection offers the connection's accounts that are not linked yet" do
      linked_id = provider_account.account_id.to_s
      free_id = "#{linked_id}-free"
      account_flow_class.any_instance.stubs(:fetch_accounts).returns(api_accounts_for([ linked_id, free_id ]))

      with_memory_cache do
        assert_equal [ linked_id, free_id ].sort, offered_account_ids.sort
      end
      link_provider_account(provider_account)

      with_memory_cache do
        result = account_flow.select_accounts_result(accountable_type: selectable_accountable_type)
        assert result.success?
        assert_equal provider_item, result.item
        assert_equal [ free_id ], offered_account_ids
      end
    end

    test "lifecycle: selection offers nothing for a type the provider does not support" do
      unsupported_type = (Accountable::TYPES - "Provider::#{provider_item.provider_key.camelize}Adapter".constantize.supported_account_types).first
      account_flow_class.any_instance.stubs(:fetch_accounts).returns(api_accounts_for([ "any-account" ]))

      with_memory_cache do
        assert_equal [ "any-account" ], offered_account_ids
        assert_empty account_flow.select_accounts_result(accountable_type: unsupported_type).available_accounts
      end
    end

    test "lifecycle: a provider API error reaches the flow as an api_error" do
      account_flow_class.any_instance.stubs(:fetch_accounts).raises(provider_api_error)

      with_memory_cache do
        assert_equal [ "api_error", provider_api_error.message ], account_flow.preload_payload.values_at(:error, :error_message)

        result = account_flow.select_accounts_result(accountable_type: selectable_accountable_type)
        assert_equal [ :api_error, provider_api_error.message ], [ result.status, result.message ]
        assert result.provider_error?
      end
    end

    test "lifecycle: each connection caches its own accounts under the provider's key" do
      second_item = provider_item.dup.tap { |item| item.save!(validate: false) }
      first_key = account_flow_class.cache_key(provider_item.family, provider_item)

      assert first_key.start_with?("#{provider_item.provider_key}_accounts_")
      refute_equal first_key, account_flow_class.cache_key(provider_item.family, second_item)

      with_memory_cache do
        account_flow_class.any_instance.stubs(:fetch_accounts).returns(api_accounts_for([ "only-on-the-first" ]))
        assert account_flow.preload_payload[:has_accounts]

        account_flow_class.any_instance.stubs(:fetch_accounts).returns([])
        assert_equal false, account_flow_class.new(family: provider_item.family, item: second_item).preload_payload[:has_accounts]
      end
    end
  end

  private
    def account_flow_class
      provider_item.class::AccountFlow
    end

    def account_flow
      account_flow_class.new(family: provider_item.family, item: provider_item)
    end

    def offered_account_ids
      account_flow.select_accounts_result(accountable_type: selectable_accountable_type)
                  .available_accounts.map { |account| account.with_indifferent_access[:id].to_s }
    end

    def with_memory_cache
      original = Rails.cache
      Rails.cache = ActiveSupport::Cache::MemoryStore.new
      yield
    ensure
      Rails.cache = original
    end

    def provider_account
      provider_item.provider_accounts.first
    end

    def link_provider_account(record)
      account = provider_item.family.accounts.create!(name: "Linked #{record.class.name}", balance: 0, currency: "USD", accountable: Investment.new)
      [ account, AccountProvider.create!(account: account, provider: record) ]
    end

    def create_holding(account, link)
      account.holdings.create!(
        security: securities(:aapl), date: Date.current, qty: 1, price: 10, amount: 10,
        currency: "USD", account_provider: link
      )
    end
end
