require "test_helper"
require "timeout"
require_relative "../../support/provider_ingestion_test_helper"

class QuestradeItem::CredentialSessionTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper, ActiveJob::TestHelper
  self.use_transactional_tests = false
  Session = QuestradeItem::CredentialSession
  Fence = Provider::AccountData::LegacyWriterFence
  Request = QuestradeAccount::ActivitiesRequest
  API = "https://api01.iq.questrade.com"

  setup do
    DebugLogEntry.stubs(:capture)
    Sentry.stubs(:capture_exception)
    Account.any_instance.stubs(:sync_later)
    Account.any_instance.stubs(:broadcast_sync_complete)
    QuestradeItem.any_instance.stubs(:broadcast_replace_to)
    clear_enqueued_jobs
  end

  teardown { clear_enqueued_jobs }

  test "one operation commits rotation before reads and holds drain and credential exclusion without a row transaction" do
    with_source do |item, _source, _account|
      post = token_response do
        assert_equal 0, ApplicationRecord.connection.open_transactions
        assert item.reload.requires_update?
        assert_equal :busy, concurrent { Fence.with_exclusive(item) { :entered } }
        assert_equal :busy, concurrent { Session.with(item) { :entered } }
      end
      get = stub_request(:get, "#{API}/v1/accounts").to_return do
        assert_equal 0, ApplicationRecord.connection.open_transactions
        assert_equal "rotated-token", item.reload.refresh_token
        assert item.good?
        { status: 200, body: '{"accounts":[]}' }
      end

      Session.with(item) do |session|
        assert_equal [], session.provider.list_accounts[:accounts]
        assert_equal [], item.questrade_provider.list_accounts[:accounts]
      end

      assert_requested post, times: 1
      assert_requested get, times: 2
      assert_equal :entered, concurrent { Fence.with_exclusive(item) { :entered } }
    end
  end

  test "public facade and direct importer refuse transitional or native ownership before transport and stats" do
    with_source do |item, _source, _account|
      facade = item.questrade_provider
      sync = item.syncs.create!
      control = ProviderMigrationControl.create!(family: item.family, provider_key: "questrade", legacy_type: "QuestradeItem", legacy_id: item.id)
      Provider::Questrade.expects(:post).never
      %w[quiescing active retired rollback_pending].each do |state|
        control.update!(state: state)
        before = [ item.reload.attributes, sync.reload.attributes ]
        assert_raises(Fence::OwnershipChanged) { facade.list_accounts }
        assert_raises(Fence::OwnershipChanged) { QuestradeItem::Importer.new(item, sync: sync).import }
        assert_raises(Fence::OwnershipChanged) { QuestradeItem::Syncer.new(item).perform_sync(sync) }
        assert_equal before, [ item.reload.attributes, sync.reload.attributes ]
      end
    end
  end

  test "public importer uses one refresh across discovery balances holdings and activities before deferred dispatch" do
    with_source do |item, source, _account|
      source.update!(sync_start_date: Date.current)
      sync = item.syncs.create!
      post = token_response
      stub_request(:get, "#{API}/v1/accounts").to_return(status: 200,
        body: { accounts: [ { number: "123", type: "Margin", status: "Active" } ] }.to_json)
      stub_request(:get, "#{API}/v1/accounts/123/balances").to_return(status: 200,
        body: { perCurrencyBalances: [ { currency: "CAD", cash: 10 } ], combinedBalances: [ { currency: "CAD", totalEquity: 15 } ] }.to_json)
      stub_request(:get, "#{API}/v1/accounts/123/positions").to_return(status: 200, body: '{"positions":[]}')
      stub_request(:get, "#{API}/v1/accounts/123/activities").with(query: hash_including("startTime", "endTime"))
        .to_return(status: 200, body: '{"activities":[]}')
      destination = mock("activity queue")
      QuestradeActivitiesFetchJob.expects(:set).with { |wait_until:| wait_until.is_a?(Time) }.returns(destination)
      destination.expects(:perform_later).with do |queued, request_id:, revision:|
        assert_equal source.id, queued.id
        request = Request.read(queued.reload)
        assert_equal request.fetch("id"), request_id
        assert_equal queued.activities_fetch_revision, revision
        assert_equal sync.id, request.fetch("context").fetch("sync_lineage").first.fetch("id")
        assert_equal 0, request.fetch("retry_count")
        assert_equal Date.current.iso8601, request.fetch("start_date")
        assert_equal :entered, concurrent { Session.with(QuestradeItem.find(item.id)) { :entered } }
        true
      end

      QuestradeItem::Importer.new(item, sync: sync).import

      assert_requested post, times: 1
      assert_equal "rotated-token", item.reload.refresh_token
      assert item.good?
      assert_equal BigDecimal("15"), source.reload.current_balance
      assert source.activities_fetch_pending?
      assert_equal 1, sync.reload.sync_stats.fetch("accounts_imported")
    end
  end

  test "timeout spends the single-use token once and refuses reuse until explicit replacement" do
    with_source do |item, _source, _account|
      post = stub_request(:post, Provider::Questrade::LOGIN_URL).to_raise(Net::ReadTimeout.new("private token"))
      facade = item.questrade_provider

      assert_raises(Provider::Questrade::AuthenticationError) { facade.list_accounts }
      assert item.reload.requires_update?
      assert_equal "original-token", item.refresh_token
      assert_raises(Provider::Questrade::AuthenticationError) { item.questrade_provider.list_accounts }
      assert_requested post, times: 1
      assert_not_requested :get, "#{API}/v1/accounts"

      Session.with(item, allow_unusable: true) { |session| session.replace!(refresh_token: "replacement-token") }
      fresh_post = token_response(expected: "replacement-token")
      stub_request(:get, "#{API}/v1/accounts").to_return(status: 200, body: '{"accounts":[]}')
      assert_equal [], facade.list_accounts[:accounts]
      assert_requested fresh_post, times: 1
      assert item.reload.good?
    end
  end

  test "failed replacement commit leaves durable refusal and never lends the uncommitted bearer" do
    with_source do |item, _source, _account|
      post = token_response
      callback = lambda do |changed|
        raise IOError, "simulated credential commit failure" if changed.id == item.id && changed.refresh_token == "rotated-token"
      end
      QuestradeItem.set_callback(:update, :after, callback)
      begin
        assert_raises(IOError) { item.questrade_provider.list_accounts }
      ensure
        QuestradeItem.skip_callback(:update, :after, callback)
      end

      assert item.reload.requires_update?
      assert_equal "original-token", item.refresh_token
      assert_raises(Provider::Questrade::AuthenticationError) { item.questrade_provider.list_accounts }
      assert_requested post, times: 1
      assert_not_requested :get, "#{API}/v1/accounts"
    end
  end

  test "a changed credential tuple after the response cannot install its stale replacement" do
    with_source do |item, _source, _account|
      post = token_response do
        QuestradeItem.where(id: item.id).update_all(refresh_token: "outside-replacement")
      end

      assert_raises(Fence::OwnershipChanged) { item.questrade_provider.list_accounts }

      assert_equal "outside-replacement", item.reload.refresh_token
      assert item.requires_update?
      assert_requested post, times: 1
      assert_not_requested :get, "#{API}/v1/accounts"
    end
  end

  test "a cached SDK cannot escape the operation or switch family" do
    with_source do |item, _source, _account|
      provider = nil
      Session.with(item) { |session| provider = session.provider }
      Provider::Questrade.expects(:post).never
      assert_raises(Fence::OwnershipChanged) { provider.list_accounts }
      facade = item.questrade_provider
      original_family = item.family
      foreign = Family.create!(name: "Foreign credential owner")
      begin
        QuestradeItem.where(id: item.id).update_all(family_id: foreign.id)
        item.reload
        assert_raises(Fence::OwnershipChanged) { facade.list_accounts }
      ensure
        QuestradeItem.where(id: item.id).update_all(family_id: original_family.id)
        foreign.destroy!
      end
    end
  end

  test "parent cancellation after exchange response denies persistence and importer recovery writes" do
    with_source do |item, _source, _account|
      parent = item.family.syncs.create!
      sync = item.syncs.create!(parent: parent)
      before = sync.attributes
      post = token_response { parent.update!(cancel_requested_at: Time.current) }

      assert_raises(Fence::OwnershipChanged) { QuestradeItem::Importer.new(item, sync: sync).import }

      assert_equal before, sync.reload.attributes
      assert_nil item.reload.raw_payload
      assert_equal "original-token", item.refresh_token
      assert item.requires_update?
      assert_requested post, times: 1
      assert_not_requested :get, "#{API}/v1/accounts"
    end
  end

  test "a competing session blocks controller replacement and direct importer before use" do
    with_source do |item, _source, _account|
      skip "Requires two database sessions" if ApplicationRecord.connection_pool.size < 2
      entered, release = Queue.new, Queue.new
      thread = Thread.new do
        ApplicationRecord.connection_pool.with_connection do
          Session.with(QuestradeItem.find(item.id)) { entered << true; release.pop }
        end
      end
      Timeout.timeout(5) { entered.pop }
      Provider::Questrade.expects(:post).never
      assert_raises(Fence::Busy) { Session.with(item, allow_unusable: true) { |session| session.replace!(refresh_token: "rival") } }
      assert_raises(Fence::Busy) { QuestradeItem::Importer.new(item).import }
      assert_equal "original-token", item.reload.refresh_token
    ensure
      release << true if release
      thread&.join(5)
      thread&.kill if thread&.alive?
      thread&.join
    end
  end

  test "deferred activity enqueue releases permits and captures the original source and completed parent" do
    with_source do |item, source, account|
      sync = item.syncs.create!
      delivery = nil
      destination = mock("activity queue")
      QuestradeActivitiesFetchJob.expects(:set).with { |wait_until:| wait_until.is_a?(Time) }.returns(destination)
      destination.expects(:perform_later).with do |queued, request_id:, revision:|
        assert_equal source.id, queued.id
        request = Request.read(queued.reload)
        assert_equal Date.current.iso8601, request.fetch("start_date")
        assert_equal 0, request.fetch("retry_count")
        assert_equal :entered, concurrent { Session.with(QuestradeItem.find(item.id)) { :entered } }
        delivery = { request_id: request_id, revision: revision }
        true
      end
      QuestradeActivitiesFetchJob.enqueue_for(source, start_date: Date.current, sync: sync)
      assert source.reload.activities_fetch_pending?
      original = Request.read(source)
      assert_equal sync.id, original.fetch("context").fetch("sync_lineage").first.fetch("id")
      assert_not_includes original.inspect, "original-token"
      sync.update!(status: :completed, completed_at: Time.current)
      post = token_response
      stub_request(:get, "#{API}/v1/accounts/123/activities").with(query: hash_including("startTime", "endTime"))
        .to_return(status: 200, body: { activities: [ { type: "Interest", transactionDate: Date.current.iso8601,
          netAmount: 1, currency: "CAD", description: "Cash interest" } ] }.to_json)

      QuestradeActivitiesFetchJob.perform_now(source, **delivery)

      assert_not source.reload.activities_fetch_pending?
      assert source.last_activities_sync
      assert_equal "completed", Request.read(source).fetch("state")
      assert_equal 1, account.entries.count
      assert_equal "rotated-token", item.reload.refresh_token
      assert_requested post, times: 1
      assert sync.reload.completed?
    end
  end

  test "legacy job arguments refuse and relinked delivery cancels only its original request" do
    with_source do |item, source, account|
      delivery = enqueue_activity_request(source)
      before = source.attributes
      original = Request.read(source)
      Provider::Questrade.expects(:post).never
      assert_raises(Fence::OwnershipChanged) { QuestradeActivitiesFetchJob.perform_now(source) }
      assert_equal before, source.reload.attributes
      [ { start_date: Date.current - 1 }, { retry_count: Request::MAX_RETRIES }, { context: {} } ].each do |legacy_arguments|
        assert_raises(Fence::OwnershipChanged) { QuestradeActivitiesFetchJob.perform_now(source, **delivery, **legacy_arguments) }
        assert_equal before, source.reload.attributes
      end
      other = item.family.accounts.create!(name: "Replacement", currency: "CAD", balance: 0, accountable: Investment.new)
      source.account_provider.update!(account: other)
      QuestradeActivitiesFetchJob.perform_now(source, **delivery)

      cancelled = Request.read(source.reload)
      assert_equal "cancelled", cancelled.fetch("state")
      assert_equal original.fetch("context"), cancelled.fetch("context")
      assert_equal original.fetch("id"), cancelled.fetch("id")
      assert_not source.activities_fetch_pending?
      assert_nil source.last_activities_sync
      assert_nil source.raw_activities_payload
      assert_empty account.entries
      assert_empty other.entries
    end
  end

  test "aborted importer discards deferred enqueue without leaving an unqueued pending flag" do
    with_source do |item, source, _account|
      QuestradeActivitiesFetchJob.expects(:perform_later).never
      assert_raises(IOError) do
        Session.with(item) do
          QuestradeActivitiesFetchJob.enqueue_for(source, start_date: Date.current)
          raise IOError, "later importer failure"
        end
      end
      assert_not source.reload.activities_fetch_pending?
      assert_nil source.last_activities_sync
      assert_nil source.activities_fetch_request
      assert_equal 0, source.activities_fetch_revision
      assert_nil source.activities_fetch_due_at
      assert_no_enqueued_jobs
    end
  end

  test "cancelled original activity Sync terminalizes its request and a new Sync can replace it" do
    with_source do |item, source, _account|
      sync = item.syncs.create!
      delivery = enqueue_activity_request(source, sync: sync)
      sync.update!(cancel_requested_at: Time.current)
      Provider::Questrade.expects(:post).never

      QuestradeActivitiesFetchJob.perform_now(source, **delivery)

      cancelled = Request.read(source.reload)
      assert_equal "cancelled", cancelled.fetch("state")
      assert_equal "original_context_unavailable", cancelled.fetch("disposition")
      assert_not source.activities_fetch_pending?
      assert_nil source.last_activities_sync
      assert_no_enqueued_jobs

      replacement_sync = item.syncs.create!
      replacement = enqueue_activity_request(source, sync: replacement_sync)
      current = Request.read(source.reload)
      assert_not_equal delivery.fetch(:request_id), replacement.fetch(:request_id)
      assert_operator replacement.fetch(:revision), :>, delivery.fetch(:revision)
      assert_equal delivery.fetch(:request_id), current.fetch("replaces_id")
      assert_equal replacement_sync.id, current.fetch("context").fetch("sync_lineage").first.fetch("id")
      assert source.activities_fetch_pending?
      before = source.attributes
      QuestradeActivitiesFetchJob.perform_now(source, **delivery)
      assert_equal before, source.reload.attributes
    end
  end

  test "unavailable activity response never becomes successful empty history" do
    with_source do |_item, source, _account|
      delivery = enqueue_activity_request(source)
      token_response
      stub_request(:get, "#{API}/v1/accounts/123/activities").with(query: hash_including("startTime", "endTime"))
        .to_return(status: 400, body: '{}')

      assert_raises(Provider::Questrade::Error) do
        QuestradeActivitiesFetchJob.perform_now(source, **delivery)
      end

      assert_nil source.reload.last_activities_sync
      assert_nil source.raw_activities_payload
      assert_not source.activities_fetch_pending?
      assert_equal "failed", Request.read(source).fetch("state")
      assert_no_enqueued_jobs
    end
  end

  test "activity ownership denial after HTTP does not clear flags or write raw activity progress" do
    with_source do |item, source, _account|
      delivery = enqueue_activity_request(source)
      original = Request.read(source)
      token_response
      stub_request(:get, "#{API}/v1/accounts/123/activities").with(query: hash_including("startTime", "endTime"))
        .to_return do
          QuestradeItem.where(id: item.id).update_all(scheduled_for_deletion: true)
          { status: 200, body: '{"activities":[]}' }
        end

      assert_raises(Fence::OwnershipChanged) { QuestradeActivitiesFetchJob.perform_now(source, **delivery) }

      running = Request.read(source.reload)
      assert_equal "running", running.fetch("state")
      assert_equal original.fetch("context"), running.fetch("context")
      assert_equal delivery.fetch(:request_id), running.fetch("id")
      assert_equal delivery.fetch(:revision) + 1, source.activities_fetch_revision
      assert_equal 1, running.fetch("attempt")
      assert source.activities_fetch_pending?
      assert_nil source.last_activities_sync
      assert_nil source.raw_activities_payload
      assert_no_enqueued_jobs
    end
  end

  [ false, true ].each do |replace_link|
    test "delayed enqueue failure retains its durable receipt with #{replace_link ? "a replacement" : "the original"} link" do
      with_source do |item, source, _account|
        delivery = enqueue_activity_request(source)
        original = Request.read(source)
        token_response
        stub_request(:get, "#{API}/v1/accounts/123/activities").with(query: hash_including("startTime", "endTime"))
          .to_return(status: 200, body: '{"activities":[]}')
        destination = mock("delayed queue")
        QuestradeActivitiesFetchJob.expects(:set).with { |wait_until:| wait_until == source.reload.activities_fetch_due_at }.returns(destination)
        destination.expects(:perform_later).with do |queued, request_id:, revision:|
          assert_equal source.id, queued.id
          assert_equal delivery.fetch(:request_id), request_id
          assert_equal source.activities_fetch_revision, revision
          assert_equal :entered, concurrent { Session.with(QuestradeItem.find(item.id)) { :entered } }
          if replace_link
            replacement = item.family.accounts.create!(name: "New owner", currency: "CAD", balance: 0, accountable: Investment.new)
            source.account_provider.update!(account: replacement)
          end
          true
        end.raises(IOError, "queue unavailable")

        assert_raises(IOError) do
          QuestradeActivitiesFetchJob.perform_now(source, **delivery)
        end

        assert source.reload.activities_fetch_pending?
        deferred = Request.read(source)
        assert_equal "retry_wait", deferred.fetch("state")
        assert_equal original.fetch("context"), deferred.fetch("context")
        assert_equal delivery.fetch(:request_id), deferred.fetch("id")
        assert_equal 1, deferred.fetch("retry_count")
        assert_equal delivery.fetch(:revision) + 2, source.activities_fetch_revision
        assert source.activities_fetch_due_at
        assert_nil source.last_activities_sync
        assert_nil source.raw_activities_payload
        assert_equal "rotated-token", item.reload.refresh_token
      end
    end
  end

  private
    def enqueue_activity_request(source, sync: nil)
      QuestradeActivitiesFetchJob.enqueue_for(source, start_date: Date.current, sync: sync)
      request = Request.read(source.reload)
      assert_equal "queued", request.fetch("state")
      assert_enqueued_with(job: QuestradeActivitiesFetchJob,
        args: [ source, { request_id: request.fetch("id"), revision: source.activities_fetch_revision } ])
      clear_enqueued_jobs
      { request_id: request.fetch("id"), revision: source.activities_fetch_revision }
    end

    def token_response(expected: "original-token", &before_response)
      stub_request(:post, Provider::Questrade::LOGIN_URL)
        .with(body: { grant_type: "refresh_token", refresh_token: expected })
        .to_return do
          assert_equal 0, ApplicationRecord.connection.open_transactions
          before_response&.call
          { status: 200, body: { access_token: "access-token", refresh_token: "rotated-token", api_server: "#{API}/", expires_in: 1800 }.to_json }
        end
    end

    def concurrent(&block)
      skip "Requires two database sessions" if ApplicationRecord.connection_pool.size < 2
      worker = Thread.new do
        ApplicationRecord.connection_pool.with_connection(&block)
      rescue Fence::Busy
        :busy
      end
      Timeout.timeout(5) { worker.value }
    ensure
      worker&.kill if worker&.alive?
      worker&.join
    end

    def with_source
      with_provider_encryption do
        family = Family.create!(name: "Questrade credential admission")
        item = family.questrade_items.create!(name: "Questrade", refresh_token: "original-token")
        source = item.questrade_accounts.create!(name: "Brokerage", currency: "CAD", questrade_account_id: "123")
        account = family.accounts.create!(name: "Brokerage", currency: "CAD", balance: 0, accountable: Investment.new)
        AccountProvider.create!(account: account, provider: source)
        yield item, source, account
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
