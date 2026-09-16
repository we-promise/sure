require "test_helper"
require "timeout"
require_relative "../../support/provider_ingestion_test_helper"

class SimplefinCredentialMaintenanceTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper
  self.use_transactional_tests = false

  Fence = Provider::AccountData::LegacyWriterFence
  Update = SimplefinItem::ConnectionUpdate

  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("security:backfill_encryption")
  end

  test "database revisions advance on update_columns credential changes and survive ABA" do
    with_item do |item|
      original = item.access_url
      assert_equal 0, item.credential_revision

      item.update_columns(access_url: "https://example.com/reconnected")
      assert_equal 1, item.reload.credential_revision
      item.update_columns(access_url: original)

      assert_equal original, item.reload.access_url
      assert_equal 2, item.credential_revision
    end
  end

  test "direct SQL insertion cannot introduce a negative credential revision" do
    with_item do |item|
      rejected_id = SecureRandom.uuid
      error = assert_raises(ActiveRecord::StatementInvalid) do
        ApplicationRecord.connection.execute(ApplicationRecord.sanitize_sql_array([
          "INSERT INTO simplefin_items (id, family_id, name, credential_revision, created_at, updated_at) " \
            "VALUES (?, ?, ?, -1, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)",
          rejected_id, item.family_id, "Invalid revision"
        ]))
      end

      assert_instance_of PG::CheckViolation, error.cause
      refute SimplefinItem.exists?(rejected_id)
    end
  end

  test "direct SQL cannot choose a replacement revision or rewind it" do
    with_item do |item|
      write_sql(item, "access_url = ?, credential_revision = ?", "https://example.com/reconnected", 99)
      assert_equal 1, item.reload.credential_revision

      [ -1, 0, 400, nil ].each do |requested|
        write_sql(item, "credential_revision = ?", requested)
        assert_equal 1, item.reload.credential_revision
      end
      write_sql(item, "access_url = ?, credential_revision = ?", "https://example.com/further-change", -100)
      assert_equal 2, item.reload.credential_revision
    end
  end

  test "unchanged stored credentials and ordinary metadata updates preserve the revision" do
    with_item do |item|
      item.update_columns(access_url: "https://example.com/reconnected")
      item.reload
      item.update_columns(access_url: item.access_url, credential_revision: 500, status: "requires_update")
      assert_equal 1, item.reload.credential_revision
      item.update!(name: "Updated display name")
      assert_equal 1, item.reload.credential_revision
      assert_equal "requires_update", item.status
    end
  end

  test "null transitions use SQL distinctness rather than nullable inequality" do
    with_item do |item|
      item.update_columns(access_url: nil)
      assert_equal 1, item.reload.credential_revision
      item.update_columns(access_url: nil, credential_revision: 0)
      assert_equal 1, item.reload.credential_revision
      item.update_columns(access_url: "https://example.com/restored")
      assert_equal 2, item.reload.credential_revision
    end
  end

  test "rolled back credential SQL also rolls back its revision" do
    with_item do |item|
      original = item.access_url
      SimplefinItem.transaction do
        item.update_columns(access_url: "https://example.com/uncommitted")
        assert_equal 1, item.reload.credential_revision
        raise ActiveRecord::Rollback
      end
      assert_equal original, item.reload.access_url
      assert_equal 0, item.credential_revision
    end
  end

  test "access URL maintenance rereads a stale batch after a committed reconnect" do
    with_item do |item|
      stale = SimplefinItem.find(item.id)
      current_url = "https://example.com/current-credential"
      in_another_session { SimplefinItem.find(item.id).update_columns(access_url: current_url) }
      stale.define_singleton_method(:access_url) { raise "Must not read the stale batch credential" }

      result = run_access_url_task(stale)

      assert_equal 1, result.fetch("updated")
      assert_equal 0, result.fetch("failed_count")
      assert_equal current_url, item.reload.access_url
      assert_equal 1, item.credential_revision
    end
  end

  test "security backfill rereads both credentials and payloads under the credential lock" do
    with_item do |item|
      stale = SimplefinItem.find(item.id)
      current_url = "https://example.com/current-credential"
      payload = { "accounts" => [ { "id" => "retained-account" } ] }
      institution = { "name" => "Current institution" }
      in_another_session do
        SimplefinItem.find(item.id).update_columns(access_url: current_url,
          raw_payload: payload, raw_institution_payload: institution)
      end
      %i[access_url raw_payload raw_institution_payload].each do |field|
        stale.define_singleton_method(field) { raise "Must not read stale backfill input" }
      end

      result = run_backfill(stale)

      assert_equal 1, result.fetch(:updated)
      assert_equal 0, result.fetch(:failed_count)
      assert_equal current_url, item.reload.access_url
      assert_equal payload, item.raw_payload
      assert_equal institution, item.raw_institution_payload
      assert_equal 1, item.credential_revision
    end
  end

  test "both maintenance writers fail without rewriting while another credential session is active" do
    with_item do |item|
      original = item.attributes.slice("access_url", "raw_payload", "raw_institution_payload", "credential_revision")
      hold_credential_session(item) do
        access_result = run_access_url_task(SimplefinItem.find(item.id))
        backfill_result = run_backfill(SimplefinItem.find(item.id))

        assert_equal 0, access_result.fetch("updated")
        assert_equal 1, access_result.fetch("failed_count")
        assert_equal Fence::Busy.name, access_result.fetch("failed_samples").sole.fetch("error")
        assert_equal 0, backfill_result.fetch(:updated)
        assert_equal 1, backfill_result.fetch(:failed_count)
        assert_equal Fence::Busy.name, backfill_result.fetch(:failed_samples).sole.fetch(:error)
      end
      assert_equal original, item.reload.attributes.slice(*original.keys)
    end
  end

  test "maintenance uses short row transactions inside migration and credential admission" do
    with_item do |item|
      observations = []
      callback = lambda do |current|
        next unless current.id == item.id
        observations << ApplicationRecord.connection.open_transactions
        credential_result = in_another_session do
          Update.with_item(SimplefinItem.find(item.id)) { :unexpected }
        rescue Fence::Busy
          :busy
        end
        drain_result = in_another_session do
          Fence.with_exclusive(SimplefinItem.find(item.id)) { :unexpected }
        rescue Fence::Busy
          :busy
        end
        assert_equal :busy, credential_result
        assert_equal :busy, drain_result
      end
      SimplefinItem.set_callback(:update, :before, callback)
      begin
        assert_equal 1, run_access_url_task(item).fetch("updated")
      ensure
        SimplefinItem.skip_callback(:update, :before, callback)
      end
      assert_equal 1, observations.size
      assert_operator observations.sole, :>, 0
      assert_equal 0, ApplicationRecord.connection.open_transactions
    end
  end

  test "both maintenance writers refuse quiescing native or deleting items" do
    [ "quiescing", "active", "deleting" ].each do |state|
      with_item do |item|
        if state == "deleting"
          item.update_columns(scheduled_for_deletion: true)
        else
          ProviderMigrationControl.create!(family: item.family, provider_key: "simplefin",
            legacy_type: "SimplefinItem", legacy_id: item.id, state: state)
        end
        original = item.reload.access_url
        assert_equal 0, run_access_url_task(item).fetch("updated")
        assert_equal 0, run_backfill(item).fetch(:updated)
        assert_equal original, item.reload.access_url
        assert_equal 0, item.credential_revision
      end
    end
  end

  test "maintenance refuses ownership or deletion drift between admission and the row lock" do
    %i[run_access_url_task run_backfill].each do |writer|
      %i[family deletion].each do |change|
        other_family = Family.create!(name: "Changed credential owner")
        with_item do |item|
          original = Update.method(:with_item)
          change_before_lock = lambda do |source, &operation|
            original.call(source) do |current|
              in_another_session do
                attributes = change == :family ? { family_id: other_family.id } : { scheduled_for_deletion: true }
                SimplefinItem.where(id: item.id).update_all(attributes)
              end
              operation.call(current)
            end
          end

          result = Update.stub(:with_item, change_before_lock) { send(writer, item) }.with_indifferent_access

          assert_equal 0, result.fetch(:updated)
          assert_equal 1, result.fetch(:failed_count)
          assert_equal Fence::OwnershipChanged.name, result.fetch(:failed_samples).sole.fetch(:error)
          assert_equal 0, item.reload.credential_revision
          assert_equal "https://example.com/original", item.access_url
        end
      ensure
        other_family&.destroy!
      end
    end
  end

  test "a backfill commit failure is sanitized and does not report a completed rewrite" do
    with_item do |item|
      original = item.attributes.slice("access_url", "raw_payload", "raw_institution_payload", "credential_revision")
      failure = -> { raise ActiveRecord::StatementInvalid, "private credential and payload contents" }
      result = nil

      ApplicationRecord.connection.stub(:commit_db_transaction, failure) do
        result = run_backfill(item)
      end

      assert_equal 0, result.fetch(:updated)
      assert_equal 1, result.fetch(:failed_count)
      assert_equal ActiveRecord::StatementInvalid.name, result.fetch(:failed_samples).sole.fetch(:error)
      assert_equal "SimpleFIN encryption backfill failed", result.fetch(:failed_samples).sole.fetch(:message)
      refute_includes result.inspect, "private credential"
      assert_equal original, item.reload.attributes.slice(*original.keys)
    end
  end

  test "dry runs enumerate without credential admission or writes" do
    with_item do |item|
      Update.expects(:with_item).never
      assert_equal 0, run_access_url_task(item, dry_run: true).fetch("updated")
      assert_equal 0, run_backfill(item, dry_run: true).fetch(:updated)
      assert_equal 0, item.reload.credential_revision
    end
  end

  private
    def write_sql(item, assignments, *values)
      ApplicationRecord.connection.execute(ApplicationRecord.sanitize_sql_array([
        "UPDATE simplefin_items SET #{assignments} WHERE id = ?", *values, item.id
      ]))
    end

    def run_access_url_task(record, dry_run: false)
      task = Rake::Task["sure:encrypt_access_urls"]
      task.reenable
      output = nil
      SimplefinItem.stub(:encryption_ready?, true) do
        with_batch(record) do
          output, = capture_io { task.invoke("100", nil, dry_run.to_s) }
        end
      end
      JSON.parse(output.lines.last)
    end

    def run_backfill(record, dry_run: false)
      # Exercise the task's actual per-model writer without rewriting unrelated
      # families/providers in this nontransactional test class.
      receiver = Rake::Task["security:backfill_encryption"].actions.first.binding.receiver
      with_batch(record) do
        receiver.send(:backfill_model, SimplefinItem,
          %i[access_url raw_payload raw_institution_payload], 100, dry_run)
      end
    end

    def with_batch(record, &block)
      scope = SimplefinItem.where(id: record.id).order(:id)
      scope.stub(:in_batches, ->(of:, &each_batch) { each_batch.call([ record ]) }) do
        SimplefinItem.stub(:order, scope, &block)
      end
    end

    def in_another_session(&block)
      key_provider = ActiveRecord::Encryption.key_provider
      thread = Thread.new do
        ApplicationRecord.connection_pool.with_connection do
          ActiveRecord::Encryption.with_encryption_context(key_provider: key_provider, &block)
        end
      end
      Timeout.timeout(5) { thread.value }
    ensure
      thread&.kill if thread&.alive?
      thread&.join
    end

    def hold_credential_session(item)
      entered, release = Queue.new, Queue.new
      thread = Thread.new do
        ApplicationRecord.connection_pool.with_connection do
          Update.with_item(SimplefinItem.find(item.id)) do
            entered << true
            release.pop
          end
        end
      rescue Exception => error
        entered << error
        raise
      end
      result = Timeout.timeout(5) { entered.pop }
      raise result if result.is_a?(Exception)
      yield
    ensure
      release << true if release
      Timeout.timeout(5) { thread&.join }
      thread&.value
    end

    def with_item
      with_provider_encryption do
        family = Family.create!(name: "SimpleFIN credential maintenance")
        item = family.simplefin_items.create!(name: "SimpleFIN", access_url: "https://example.com/original")
        yield item
      ensure
        if family&.persisted?
          ProviderMigrationControl.where(family: family).delete_all
          item&.reload&.destroy!
          family.destroy!
        end
      end
    end
end
