require "test_helper"
require_relative "../../../support/provider_ingestion_test_helper"

class Provider::AccountData::RuntimeInputsConcurrencyTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper
  self.use_transactional_tests = false

  test "a committed setting update in another session invalidates a worker's cached input" do
    with_connection_and_setting do |connection|
      Setting.syncs_include_pending = true
      assert_equal true, Setting.syncs_include_pending
      request_cache = RailsSettings::RequestCache.all_settings
      grant = build_grant(connection)
      update_setting_in_another_session(false)

      # The other session reset its own RequestCache; this worker still owns the
      # old one. The runtime must read the database instead of trusting it.
      assert_same request_cache, RailsSettings::RequestCache.all_settings
      assert_equal true, Setting.syncs_include_pending
      assert_raises(Provider::AccountData::StaleWriter) { grant.capture_request { flunk "Stale policy reached HTTP" } }
      assert_same request_cache, RailsSettings::RequestCache.all_settings
    end
  end

  test "configuration committed during HTTP rejects publication despite a cached preference" do
    with_connection_and_setting do |connection|
      Setting.syncs_include_pending = true
      assert_equal true, Setting.syncs_include_pending
      grant = build_grant(connection)
      _page, capture = grant.capture_request do
        update_setting_in_another_session(false)
        Provider::AccountData::Page.new(records: [], complete: true)
      end
      assert_equal true, Setting.syncs_include_pending
      assert_raises(Provider::AccountData::StaleWriter) do
        Provider::AccountData::RequestGrant.verify_capture!(connection: connection, capture: capture, require_runtime_inputs: true)
      end
    end
  end

  private
    def build_grant(connection)
      grant = Provider::AccountData::RequestGrant.new(connection)
      Provider::AccountData::Registry.stubs(:fetch).with("up").returns(Provider::AccountData::Up)
      Provider::AccountData::Up.expects(:build).returns(Provider::AccountData::Adapter.new(client: nil))
      Provider::AccountData::Registry.build(connection, observed_at: Time.current, request_grant: grant)
      grant
    end

    def update_setting_in_another_session(value)
      thread = Thread.new do
        ApplicationRecord.connection_pool.with_connection do |database|
          database.execute("SET statement_timeout = '5s'")
          begin
            Setting.syncs_include_pending = value
          ensure
            database.execute("RESET statement_timeout")
            RailsSettings::RequestCache.reset
          end
        end
      end
      assert thread.join(10), "Setting update must finish after capture released its locks"
      thread.value
    ensure
      if thread&.alive?
        thread.kill
        thread.join
      end
    end

    def with_connection_and_setting
      original = Setting.unscoped.find_by(var: "syncs_include_pending")
      original_value = original&.value
      with_provider_encryption do
        connection = create_provider_connection
        yield connection
      ensure
        connection&.reload&.destroy!
      end
    ensure
      if original
        Setting.syncs_include_pending = original_value
      else
        Setting.unscoped.where(var: "syncs_include_pending").destroy_all
      end
      Setting.clear_cache
    end
end
