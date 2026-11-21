# frozen_string_literal: true

# The model part of the provider kit's lifecycle contract: the connection and its
# accounts on the kit's base classes, the shared syncer, unlinking and destroy.
# Include it in a test case that defines `provider_item` (a persisted connection
# with at least one provider account, none of them linked to an account yet: the
# sync and unlink tests create their own links and count the unlinked ones) and
# `other_provider_account` (a provider account that belongs to a different
# account provider in the same family).
# ProviderItemLifecycleTests includes it.
module ProviderItemModelLifecycleTests
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

    test "lifecycle: a failed import reports the provider's own error when it gives one" do
      key = provider_item.provider_key
      import = :"import_latest_#{key}_data"

      provider_item.class.any_instance.stubs(import).returns(success: false, error: "Rate limited by the provider")
      with_error = Sync.create!(syncable: provider_item).tap(&:perform).reload.sync_stats["errors"]

      provider_item.class.any_instance.stubs(import).returns(success: false)
      without_error = Sync.create!(syncable: provider_item).tap(&:perform).reload.sync_stats["errors"]

      provider_item.class.any_instance.stubs(import).returns(success: false, error: "")
      blank_error = Sync.create!(syncable: provider_item).tap(&:perform).reload.sync_stats["errors"]

      assert_equal [ [ I18n.t("#{key}_items.syncer.import_failed_with_error", error: "Rate limited by the provider"), "import_error" ] ],
                   with_error.map { |error| error.values_at("message", "category") }
      assert_equal [ [ I18n.t("#{key}_items.syncer.import_failed"), "import_error" ] ],
                   without_error.map { |error| error.values_at("message", "category") }
      assert_equal without_error, blank_error
    end

    test "lifecycle: a failed sync reaches Sentry once, as the raw error tagged with the connection and the sync" do
      key = provider_item.provider_key
      error = StandardError.new("raw provider failure")
      provider_item.class.any_instance.stubs(:"import_latest_#{key}_data").raises(error)
      # Only the failure's own reports are counted, not the post-sync broadcast's.
      provider_item.class.any_instance.stubs(:broadcast_sync_complete)
      sync = Sync.create!(syncable: provider_item)
      captured = []

      Sentry.stub(:capture_exception, ->(exception, *, &block) { captured << [ exception, sentry_tags(&block) ] }) do
        sync.perform
      end

      assert_equal 1, captured.size, "expected one Sentry event, got #{captured.map { |exception, _| exception.class.name }}"
      reported, tags = captured.first
      assert_same error, reported
      assert_equal({ "#{key}_item_id": provider_item.id, sync_id: sync.id }, tags)
      assert_equal I18n.t("#{key}_items.syncer.failed"), sync.reload.error
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
  end

  private
    # The tags a Sentry.capture_exception block sets on its scope.
    def sentry_tags
      tags = {}
      scope = Object.new
      scope.define_singleton_method(:set_tags) { |new_tags| tags.merge!(new_tags) }
      yield scope if block_given?
      tags
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
