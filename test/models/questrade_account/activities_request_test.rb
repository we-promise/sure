require "test_helper"
require "timeout"
require_relative "../../support/provider_ingestion_test_helper"

class QuestradeAccount::ActivitiesRequestTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper, ActiveJob::TestHelper
  self.use_transactional_tests = false
  Request = QuestradeAccount::ActivitiesRequest
  Fence = Provider::AccountData::LegacyWriterFence
  API = "https://api01.iq.questrade.com"

  setup do
    travel_to Time.utc(2026, 9, 16, 12)
    DebugLogEntry.stubs(:capture)
    Account.any_instance.stubs(:sync_later)
    Account.any_instance.stubs(:broadcast_sync_complete)
    clear_enqueued_jobs
  end

  teardown do
    clear_enqueued_jobs
    travel_back
  end

  test "durable request fixes dates and publishes one legacy transaction with atomic completion" do
    with_source do |source, sync, account|
      assert_enqueued_with(job: QuestradeActivitiesFetchJob) { enqueue(source, sync) }
      original = Request.read(source.reload)
      assert source.activities_fetch_pending?
      assert_equal "queued", original.fetch("state")
      stub_transport([ cash_activity ]) do |request|
        assert_equal 0, ApplicationRecord.connection.open_transactions
        assert_equal Date.iso8601(original.fetch("end_date")), Time.iso8601(request.uri.query_values.fetch("endTime")).to_date
      end

      QuestradeActivitiesFetchJob.perform_now(source, **delivery(source))

      assert_equal "completed", Request.read(source.reload).fetch("state")
      assert_equal 3, source.activities_fetch_revision
      assert_not source.activities_fetch_pending?
      assert_nil source.activities_fetch_due_at
      assert source.last_activities_sync
      assert_equal BigDecimal("-15"), account.entries.sole.amount
      assert_equal "questrade", account.entries.sole.source
      before = [ source.attributes, account.entries.sole.attributes ]
      assert_no_difference "Entry.count" do
        QuestradeActivitiesFetchJob.perform_now(source, request_id: original.fetch("id"), revision: 1)
      end
      assert_equal before, [ source.reload.attributes, account.entries.sole.attributes ]
    end
  end

  test "completion beyond the incremental overlap records the original requested end instead of worker time" do
    with_source do |source, sync, account|
      source.update!(raw_activities_payload: 10.times.map { |index| cash_activity.merge("description" => "Earlier deposit #{index}") })
      enqueue(source, sync)
      end_date = Date.iso8601(Request.read(source.reload).fetch("end_date"))
      travel 45.days
      stub_transport([ cash_activity ]) do |request|
        assert_equal end_date, Time.iso8601(request.uri.query_values.fetch("endTime")).to_date
      end

      QuestradeActivitiesFetchJob.perform_now(source, **delivery(source))

      assert_equal "completed", Request.read(source.reload).fetch("state")
      assert_equal end_date, source.last_activities_sync.to_date
      assert_equal [ 23, 59, 59 ], [ source.last_activities_sync.hour, source.last_activities_sync.min, source.last_activities_sync.sec ]
      assert_equal 11, account.entries.count
      importer = QuestradeItem::Importer.new(source.questrade_item)
      assert_equal end_date - 30, importer.send(:calculate_start_date, source)
      assert_operator importer.send(:calculate_start_date, source), :<, Date.current - 30
    end
  end

  test "completion does not borrow an unrelated later timestamp as proven request coverage" do
    with_source do |source, sync, _account|
      enqueue(source, sync)
      end_date = Date.iso8601(Request.read(source.reload).fetch("end_date"))
      travel 45.days
      source.update!(last_activities_sync: Time.current)
      stub_transport([ cash_activity ])

      QuestradeActivitiesFetchJob.perform_now(source, **delivery(source))

      assert_equal end_date, source.reload.last_activities_sync.to_date
      assert_equal "completed", Request.read(source).fetch("state")
    end
  end

  test "an admitted cache write during merge is retained and the stale merge refuses publication" do
    with_source do |source, sync, account|
      enqueue(source, sync)
      stub_transport([ cash_activity ])
      intervening = cash_activity.merge("description" => "Retain concurrently staged observation", "netAmount" => 22)
      job = QuestradeActivitiesFetchJob.new
      merge = job.method(:merge_activities)
      raced_merge = lambda do |existing, incoming|
        # This uses the real admitted snapshot entrypoint while the job retains
        # its exact pre-merge cache context. Request scheduling fields do not move.
        QuestradeAccount.find(source.id).upsert_activities_snapshot!([ intervening ], mark_synced: false)
        merge.call(existing, incoming)
      end

      job.stub(:merge_activities, raced_merge) do
        assert_raises(Fence::OwnershipChanged) { job.perform(source, **delivery(source)) }
      end

      assert_equal [ intervening ], source.reload.raw_activities_payload
      assert_equal "running", Request.read(source).fetch("state")
      assert_equal 2, source.activities_fetch_revision
      assert source.activities_fetch_pending?
      assert_nil source.last_activities_sync
      assert_empty account.entries
    end
  end

  test "completion broadcasts to the original account after releasing row credential and migration locks" do
    with_source do |source, sync, account|
      enqueue(source, sync)
      stub_transport([ cash_activity ])
      Account.any_instance.unstub(:broadcast_sync_complete)
      broadcaster = mock("completion broadcaster")
      Account::SyncCompleteEvent.expects(:new).with do |recipient|
        assert_equal account.id, recipient.id
        assert_equal 0, ApplicationRecord.connection.open_transactions
        assert_nil ActiveSupport::IsolatedExecutionState[QuestradeItem::CredentialSession::CONTEXT_KEY]
        assert_nil ActiveSupport::IsolatedExecutionState[Fence::CONTEXT_KEY]
        assert_equal "completed", Request.read(source.reload).fetch("state")
        assert_equal :admitted, admit_elsewhere(source.questrade_item)
        true
      end.returns(broadcaster)
      broadcaster.expects(:broadcast).once

      QuestradeActivitiesFetchJob.perform_now(source, **delivery(source))

      assert_equal "completed", Request.read(source.reload).fetch("state")
      assert_equal 1, account.entries.count
    end
  end

  test "a failed completion broadcast cannot fail its committed receipt or repeat financial publication" do
    with_source do |source, sync, account|
      enqueue(source, sync)
      submitted = delivery(source)
      stub_transport([ cash_activity ])
      Account.any_instance.unstub(:broadcast_sync_complete)
      broadcaster = mock("unavailable completion broadcaster")
      Account::SyncCompleteEvent.expects(:new).with { |recipient| recipient.id == account.id }.returns(broadcaster)
      broadcaster.expects(:broadcast).raises(IOError, "broadcast unavailable")
      Request.any_instance.expects(:fail!).never

      assert_nothing_raised { QuestradeActivitiesFetchJob.perform_now(source, **submitted) }

      before = source.reload.attributes
      assert_equal "completed", Request.read(source).fetch("state")
      assert_equal 3, source.activities_fetch_revision
      assert_not source.activities_fetch_pending?
      assert_no_difference "Entry.count" do
        QuestradeActivitiesFetchJob.perform_now(source, **submitted)
      end
      assert_equal before, source.reload.attributes
      assert_equal 1, account.entries.count
    end
  end

  test "a relink after completion suppresses its broadcast instead of following the replacement account" do
    with_source do |source, sync, account|
      enqueue(source, sync)
      stub_transport([ cash_activity ])
      other = account.family.accounts.create!(name: "Replacement", currency: "CAD", balance: 0, accountable: Investment.new)
      broadcast = Request.method(:broadcast_completed)
      before_broadcast = lambda do |ticket|
        assert_nil ActiveSupport::IsolatedExecutionState[QuestradeItem::CredentialSession::CONTEXT_KEY]
        source.account_provider.update!(account: other)
        broadcast.call(ticket)
      end
      Account.any_instance.expects(:broadcast_sync_complete).never
      Request.any_instance.expects(:fail!).never

      Request.stub(:broadcast_completed, before_broadcast) do
        QuestradeActivitiesFetchJob.perform_now(source, **delivery(source))
      end

      assert_equal "completed", Request.read(source.reload).fetch("state")
      assert_equal 1, account.entries.count
      assert_empty other.entries
      assert_equal other.id, source.reload.current_account.id
    end
  end

  test "failed enqueue preserves the same durable request for bounded recovery" do
    with_source do |source, sync, _account|
      Request.stubs(:dispatch).raises(IOError, "queue unavailable")
      assert_raises(IOError) { enqueue(source, sync) }
      original = Request.read(source.reload)
      revision = source.activities_fetch_revision
      assert source.activities_fetch_pending?
      assert_nil source.last_activities_sync
      Request.unstub(:dispatch)

      assert_enqueued_with(job: QuestradeActivitiesFetchJob) { Request.recover_due! }

      assert_equal original, Request.read(source.reload)
      assert_equal revision, source.activities_fetch_revision
      assert source.activities_fetch_due_at > Time.current
      assert_nil source.last_activities_sync
    end
  end

  test "crashed running work is reclaimed with a new revision and the old writer cannot finalize" do
    with_source do |source, sync, _account|
      enqueue(source, sync)
      old_request = nil
      assert_raises(IOError) do
        Request.with_claim(source, **delivery(source)) do |_session, request|
          old_request = request
          raise IOError, "worker interrupted"
        end
      end
      assert_equal "running", Request.read(source.reload).fetch("state")
      travel 6.minutes
      assert_enqueued_with(job: QuestradeActivitiesFetchJob) { Request.recover_due! }
      Request.with_claim(source, **delivery(source)) do |_session, replacement|
        assert_equal 2, replacement.document.fetch("attempt")
        before = source.reload.attributes
        assert_raises(Fence::OwnershipChanged) { old_request.complete!(source) }
        assert_equal before, source.reload.attributes
        replacement.complete!(source)
      end
      assert_equal "completed", Request.read(source.reload).fetch("state")
    end
  end

  test "cancelled original parent retires only its request and a new sync obtains a new identity" do
    with_source do |source, sync, _account|
      enqueue(source, sync)
      stale_delivery = delivery(source)
      sync.update!(cancel_requested_at: Time.current)
      Provider::Questrade.expects(:post).never

      QuestradeActivitiesFetchJob.perform_now(source, **stale_delivery)

      assert_equal "cancelled", Request.read(source.reload).fetch("state")
      assert_not source.activities_fetch_pending?
      assert_nil source.last_activities_sync
      next_sync = source.questrade_item.syncs.create!
      enqueue(source, next_sync)
      current = source.reload.attributes
      refute_equal stale_delivery.fetch(:request_id), Request.read(source).fetch("id")
      QuestradeActivitiesFetchJob.perform_now(source, **stale_delivery)
      assert_equal current, source.reload.attributes
    end
  end

  test "recovery cancels a failed ancestor without borrowing a newer sync or fetching" do
    with_source do |source, sync, _account|
      parent = source.questrade_item.family.syncs.create!
      sync.update!(parent: parent)
      enqueue(source, sync)
      parent.update!(status: "failed")
      Provider::Questrade.expects(:post).never
      Request.recover_due!
      assert_equal "cancelled", Request.read(source.reload).fetch("state")
      assert_nil source.last_activities_sync
    end
  end

  test "valid empty polling has a fixed end date and only completes at its persisted budget" do
    with_source do |source, sync, _account|
      travel_to Time.utc(2026, 9, 16, 23, 59, 45)
      enqueue(source, sync)
      original_end = Request.read(source.reload).fetch("end_date")
      stub_transport([]) do |request|
        assert_equal Date.iso8601(original_end), Time.iso8601(request.uri.query_values.fetch("endTime")).to_date
      end
      (Request::MAX_RETRIES + 1).times do |index|
        QuestradeActivitiesFetchJob.perform_now(source, **delivery(source))
        if index < Request::MAX_RETRIES
          assert_nil source.reload.last_activities_sync
          assert_equal "retry_wait", Request.read(source).fetch("state")
          travel Request::RETRY_DELAY
        end
      end
      assert_equal "completed", Request.read(source.reload).fetch("state")
      assert source.last_activities_sync
    end
  end

  test "malformed upstream collection fails without a successful empty completion" do
    with_source do |source, sync, _account|
      enqueue(source, sync)
      stub_transport(nil, body: {})

      assert_raises(Provider::Questrade::Error) { QuestradeActivitiesFetchJob.perform_now(source, **delivery(source)) }

      assert_equal "failed", Request.read(source.reload).fetch("state")
      assert_nil source.last_activities_sync
      assert_nil source.raw_activities_payload
      assert_not source.activities_fetch_pending?
    end
  end

  test "unavailable reads exhaust their own request without claiming empty history" do
    with_source do |source, sync, _account|
      enqueue(source, sync)
      stub_transport(nil, status: 503)
      Provider::Questrade.any_instance.stubs(:sleep)
      Request::MAX_RETRIES.times do
        QuestradeActivitiesFetchJob.perform_now(source, **delivery(source))
        assert_equal "retry_wait", Request.read(source.reload).fetch("state")
        assert_nil source.last_activities_sync
        travel Request::RETRY_DELAY
      end
      assert_raises(Provider::Questrade::Error) { QuestradeActivitiesFetchJob.perform_now(source, **delivery(source)) }
      assert_equal "failed", Request.read(source.reload).fetch("state")
      assert_nil source.last_activities_sync
    end
  end

  test "old arguments cannot override dates retries or the request owner" do
    with_source do |source, sync, _account|
      enqueue(source, sync)
      before = source.reload.attributes
      Provider::Questrade.expects(:post).never
      assert_raises(Fence::OwnershipChanged) { QuestradeActivitiesFetchJob.perform_now(source) }
      assert_raises(Fence::OwnershipChanged) do
        QuestradeActivitiesFetchJob.perform_now(source, **delivery(source), start_date: 10.years.ago.to_date)
      end
      assert_equal before, source.reload.attributes
    end
  end

  test "changed link during HTTP cannot publish captured activities or clear its current request" do
    with_source do |source, sync, account|
      enqueue(source, sync)
      original_link = source.account_provider
      other = account.family.accounts.create!(name: "Other", currency: "CAD", balance: 0, accountable: Investment.new)
      stub_transport([ cash_activity ]) { original_link.update!(account: other) }
      assert_raises(Fence::OwnershipChanged) { QuestradeActivitiesFetchJob.perform_now(source, **delivery(source)) }
      assert_empty account.entries
      assert_empty other.entries
      assert_nil source.reload.raw_activities_payload
      assert_nil source.last_activities_sync
      assert source.activities_fetch_pending?
      travel 6.minutes
      Request.recover_due!
      assert_equal "cancelled", Request.read(source.reload).fetch("state")
    end
  end

  test "historical unowned work requires explicit nonfinancial disposition and blocks quiescence" do
    with_source do |source, _sync, account|
      source.update!(activities_fetch_pending: true, raw_activities_payload: [ cash_activity ])
      before = [ source.raw_activities_payload, source.last_activities_sync, account.attributes ]
      copier = Provider::AccountData::MigrationCopier.new(provider_key: "questrade", legacy_item_id: source.questrade_item_id)
      assert_raises(Fence::OwnershipChanged) { copier.run_quiesced }
      assert_nil ProviderMigrationControl.find_by(legacy_type: "QuestradeItem", legacy_id: source.questrade_item_id)

      Request.dispose_unowned!(source, family: account.family)

      receipt = Request.read(source.reload)
      assert_equal "legacy_unowned", receipt.fetch("origin")
      assert_equal "cancelled", receipt.fetch("state")
      assert_equal before, [ source.raw_activities_payload, source.last_activities_sync, account.reload.attributes ]
      assert_empty account.entries
      projection = Provider::AccountData::MigrationManifest.for("questrade").extract_account(source)
      assert_equal receipt, projection.payloads.fetch("activities_fetch_request")
      assert_equal source.activities_fetch_revision, projection.checkpoints.fetch("activities_fetch_revision")
    end
  end

  test "active owned work blocks copy before migration ownership changes" do
    with_source do |source, sync, _account|
      enqueue(source, sync)
      before = source.reload.attributes
      copier = Provider::AccountData::MigrationCopier.new(provider_key: "questrade", legacy_item_id: source.questrade_item_id)
      assert_raises(Fence::OwnershipChanged) { copier.run_quiesced }
      assert_nil ProviderMigrationControl.find_by(legacy_type: "QuestradeItem", legacy_id: source.questrade_item_id)
      assert_equal before, source.reload.attributes
    end
  end

  private
    def admit_elsewhere(item)
      skip "Requires two database sessions" if ApplicationRecord.connection_pool.size < 2
      worker = Thread.new do
        QuestradeItem::CredentialSession.with(QuestradeItem.find(item.id)) { :admitted }
      end
      Timeout.timeout(5) { worker.value }
    ensure
      worker&.kill if worker&.alive?
      worker&.join
    end

    def enqueue(source, sync)
      QuestradeActivitiesFetchJob.enqueue_for(source, start_date: Date.current, sync: sync)
    end

    def delivery(source)
      source.reload
      { request_id: Request.read(source).fetch("id"), revision: source.activities_fetch_revision }
    end

    def cash_activity
      { "type" => "Deposits", "action" => "CON", "transactionDate" => "2026-09-16T00:00:00Z",
        "netAmount" => 15, "currency" => "CAD", "description" => "Deposit" }
    end

    def stub_transport(rows, status: 200, body: nil, &before_response)
      stub_request(:post, Provider::Questrade::LOGIN_URL).to_return(status: 200,
        body: { access_token: "access", refresh_token: "rotated", api_server: "#{API}/", expires_in: 1800 }.to_json)
      stub_request(:get, "#{API}/v1/accounts/123/activities").with(query: hash_including("startTime", "endTime"))
        .to_return do |request|
          before_response&.call(request)
          { status: status, body: (body || { activities: rows }).to_json }
        end
    end

    def with_source
      with_provider_encryption do
        family = Family.create!(name: "Questrade activity requests")
        item = family.questrade_items.create!(name: "Questrade", refresh_token: "original")
        source = item.questrade_accounts.create!(name: "Brokerage", currency: "CAD", questrade_account_id: "123")
        account = family.accounts.create!(name: "Brokerage", currency: "CAD", balance: 0, accountable: Investment.new)
        AccountProvider.create!(account: account, provider: source)
        sync = item.syncs.create!
        yield source, sync, account
      ensure
        if family
          ProviderMigrationControl.where(family: family).delete_all
          Sync.where(syncable_type: "QuestradeItem", syncable_id: family.questrade_items.select(:id)).delete_all
          Sync.where(syncable_type: "Family", syncable_id: family.id).delete_all
          AccountProvider.where(account_id: family.accounts.select(:id)).delete_all
          family.accounts.each(&:destroy!)
          family.questrade_items.destroy_all
          family.destroy!
        end
      end
    end
end
