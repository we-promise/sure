require "test_helper"

class Family::SyncerTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  setup do
    @family = families(:dylan_family)
  end

  test "syncs provider items and manual accounts" do
    family_sync = syncs(:family)
    @family.akahu_items.create!(
      name: "Test Akahu",
      app_token: "app_token",
      user_token: "user_token"
    )

    manual_accounts_count = @family.accounts.manual.count
    syncer = Family::Syncer.new(@family)

    Account.any_instance
           .expects(:sync_later)
           .with(parent_sync: family_sync, window_start_date: nil, window_end_date: nil)
           .times(manual_accounts_count)

    syncable_item_associations.each do |association|
      association.klass.any_instance
                 .expects(:sync_later)
                 .with(parent_sync: family_sync, window_start_date: nil, window_end_date: nil)
                 .times(@family.public_send(association.name).syncable.count)
    end

    syncer.perform_sync(family_sync)

    assert_equal "completed", family_sync.reload.status
  end

  test "syncs ibkr items through reflective provider discovery" do
    family_sync = syncs(:family)
    syncer = Family::Syncer.new(@family)

    assert_includes syncable_item_associations.map(&:name), :ibkr_items

    Account.any_instance.stubs(:sync_later)
    syncable_item_associations.reject { |association| association.name == :ibkr_items }.each do |association|
      association.klass.any_instance.stubs(:sync_later)
    end

    IbkrItem.any_instance
            .expects(:sync_later)
            .with(parent_sync: family_sync, window_start_date: nil, window_end_date: nil)
            .times(@family.ibkr_items.syncable.count)

    syncer.perform_sync(family_sync)
  end

  test "applies rules in one ordered run per family after sync" do
    syncer = Family::Syncer.new(@family)

    assert_enqueued_with(job: ApplyRulesJob, args: [ @family ]) do
      syncer.perform_post_sync
    end
    assert_no_enqueued_jobs(only: RuleJob)
  end

  private
    def syncable_item_associations
      Family.reflect_on_all_associations(:has_many).select do |association|
        association.name.to_s.end_with?("_items") &&
          association.klass.included_modules.include?(Syncable)
      rescue NameError
        false
      end
    end
end
