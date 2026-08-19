require "test_helper"

class AkahuItem::SyncerTest < ActiveSupport::TestCase
  setup do
    @akahu_item = AkahuItem.create!(
      family: families(:dylan_family),
      name: "Main Akahu",
      app_token: "akahu-app-credential",
      user_token: "akahu-user-credential"
    )

    AkahuItem.any_instance.stubs(:perform_post_sync)
    AkahuItem.any_instance.stubs(:broadcast_sync_complete)
  end

  test "failed import result marks sync failed and records health error" do
    AkahuItem.any_instance.stubs(:import_latest_akahu_data).returns(
      success: false,
      error: "Failed to fetch accounts data"
    )

    sync = @akahu_item.syncs.create!

    sync.perform

    sync.reload
    assert_predicate sync, :failed?
    assert_equal "Akahu import: Failed to fetch accounts data", sync.error
    assert_equal 1, sync.sync_stats["total_errors"]
    assert_equal "Akahu import: Failed to fetch accounts data", sync.sync_stats.dig("errors", 0, "message")
    assert_equal "sync_error", sync.sync_stats.dig("errors", 0, "category")
  end

  test "unexpected sync error log excludes raw exception message" do
    sensitive_message = "provider payload included account details"
    error = RuntimeError.new(sensitive_message)

    AkahuItem.any_instance.stubs(:import_latest_akahu_data).raises(error)
    Rails.logger.expects(:error).with do |message|
      message == "AkahuItem::Syncer - Unexpected sync error: RuntimeError"
    end.once

    sync = @akahu_item.syncs.create!
    scope = RecordingSentryScope.new
    Sentry.expects(:capture_exception).with do |captured_error|
      captured_error.is_a?(AkahuItem::Syncer::SafeSyncError) &&
        !captured_error.equal?(error) &&
        captured_error.cause.nil? &&
        captured_error.message == I18n.t("akahu_item.errors.sync_failed") &&
        !captured_error.message.include?(sensitive_message)
    end.yields(scope).once

    sync.perform

    sync.reload
    assert_predicate sync, :failed?
    assert_equal I18n.t("akahu_item.errors.sync_failed"), sync.error
    assert_equal I18n.t("akahu_item.errors.sync_failed"), sync.sync_stats.dig("errors", 0, "message")
    assert_not_includes sync.sync_stats.dig("errors", 0, "message"), sensitive_message
    assert_equal({ sync_id: sync.id }, scope.tags)
    assert_empty scope.contexts
  end

  class RecordingSentryScope
    attr_reader :tags, :contexts

    def initialize
      @tags = {}
      @contexts = {}
    end

    def set_tags(tags)
      @tags.merge!(tags)
    end

    def set_context(name, context)
      @contexts[name] = context
    end
  end
end
