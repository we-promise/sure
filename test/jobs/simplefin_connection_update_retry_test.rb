require "test_helper"
require "active_job/queue_adapters/sidekiq_adapter"
require_relative "../support/provider_ingestion_test_helper"

class SimplefinConnectionUpdateRetryTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper, ActiveJob::TestHelper
  self.use_transactional_tests = false

  Fence = Provider::AccountData::LegacyWriterFence

  test "the serialized Sidekiq wrapper disables retries for this claim job" do
    family_id, claim_id = SecureRandom.uuid, SecureRandom.uuid
    job = SimplefinConnectionUpdateJob.new(family_id: family_id, claim_id: claim_id)
    payloads = []
    client = Sidekiq::Client.new
    # Keep real adapter serialization and wrapped-class option normalization;
    # replace only the Redis write after those options have been merged.
    client.stub(:raw_push, ->(jobs) { payloads.concat(Sidekiq.load_json(Sidekiq.dump_json(jobs))); true }) do
      Sidekiq::Client.stub(:new, client) do
        ActiveJob::QueueAdapters::SidekiqAdapter.new.enqueue(job)
      end
    end

    payload = payloads.sole
    assert_equal "Sidekiq::ActiveJob::Wrapper", payload.fetch("class")
    assert_equal "SimplefinConnectionUpdateJob", payload.fetch("wrapped")
    assert_equal false, payload.fetch("retry")
    assert_equal job.job_id, payload.fetch("args").sole.fetch("job_id")
    assert_equal job.provider_job_id, payload.fetch("jid")
    arguments = payload.fetch("args").sole.fetch("arguments").sole
    assert_equal family_id, arguments.fetch("family_id")
    assert_equal claim_id, arguments.fetch("claim_id")
    refute arguments.key?("setup_token")
    refute arguments.key?("old_simplefin_item_id")
  end

  test "an unexpected post-claim error still propagates after credentials commit" do
    with_item do |item|
      posted, token, new_url = successful_claim
      claim = SimplefinItem::ConnectionUpdate.prepare(item, setup_token: token)
      diagnostics = []

      DebugLogEntry.stub(:capture, ->(**attributes) { diagnostics << attributes }) do
        VCR.turned_off do
          SyncJob.stub(:perform_later, ->(*) { raise IOError, "Private enqueue failure" }) do
            assert_no_enqueued_jobs do
              assert_raises(IOError) do
                SimplefinConnectionUpdateJob.perform_now(family_id: item.family_id, claim_id: claim.id)
              end
            end
          end
        end
      end

      assert_equal new_url, item.reload.access_url
      original_sync = item.syncs.sole
      assert claim.reload.installed?
      assert_equal original_sync.id, claim.sync_id
      VCR.turned_off do
        assert_enqueued_with(job: SyncJob, args: [ original_sync ]) do
          SimplefinConnectionUpdateJob.perform_now(family_id: item.family_id, claim_id: claim.id)
        end
      end
      assert_equal original_sync.id, item.syncs.reload.sole.id
      assert_requested posted, times: 1
      assert_sanitized_failure(diagnostics, item, claim, "IOError", token, new_url)
    end
  end

  test "an installation deadlock is discarded and explicit replay uses the saved response" do
    with_item do |item|
      original_url = item.access_url
      posted, token, new_url = successful_claim
      claim = SimplefinItem::ConnectionUpdate.prepare(item, setup_token: token)
      issued_writes = []
      failure = lambda do |record|
        next unless record.id == item.id
        issued_writes << SimplefinItem.find(item.id).access_url
        raise ActiveRecord::Deadlocked, "Private database failure"
      end
      SimplefinItem.set_callback(:update, :after, failure)
      diagnostics = []

      begin
        DebugLogEntry.stub(:capture, ->(**attributes) { diagnostics << attributes }) do
          VCR.turned_off do
            assert_no_enqueued_jobs do
              SimplefinConnectionUpdateJob.perform_now(family_id: item.family_id, claim_id: claim.id)
            end
          end
        end
      ensure
        SimplefinItem.skip_callback(:update, :after, failure)
      end

      assert_equal [ new_url ], issued_writes
      assert_equal original_url, item.reload.access_url
      assert_empty item.syncs
      assert claim.reload.claimed?
      assert_equal new_url, claim.response.fetch("access_url")
      VCR.turned_off do
        assert_enqueued_jobs 1, only: SyncJob do
          SimplefinConnectionUpdateJob.perform_now(family_id: item.family_id, claim_id: claim.id)
        end
      end
      assert claim.reload.installed?
      assert_equal new_url, item.reload.access_url
      assert_requested posted, times: 1
      assert_sanitized_failure(diagnostics, item, claim, "ActiveRecord::Deadlocked", token, new_url)
    end
  end

  test "a deadlock scheduling sync keeps committed credentials and does not reclaim the token" do
    with_item do |item|
      posted, token, new_url = successful_claim
      claim = SimplefinItem::ConnectionUpdate.prepare(item, setup_token: token)
      diagnostics = []

      DebugLogEntry.stub(:capture, ->(**attributes) { diagnostics << attributes }) do
        VCR.turned_off do
          SyncJob.stub(:perform_later, ->(*) { raise ActiveRecord::Deadlocked, "Private enqueue failure" }) do
            assert_no_enqueued_jobs do
              SimplefinConnectionUpdateJob.perform_now(family_id: item.family_id, claim_id: claim.id)
            end
          end
        end
      end

      assert_equal new_url, item.reload.access_url
      original_sync = item.syncs.sole
      assert claim.reload.installed?
      assert_equal original_sync.id, claim.sync_id
      VCR.turned_off do
        assert_enqueued_with(job: SyncJob, args: [ original_sync ]) do
          SimplefinConnectionUpdateJob.perform_now(family_id: item.family_id, claim_id: claim.id)
        end
      end
      assert_equal original_sync.id, item.syncs.reload.sole.id
      assert_requested posted, times: 1
      assert_sanitized_failure(diagnostics, item, claim, "ActiveRecord::Deadlocked", token, new_url)
    end
  end

  test "an ambiguous HTTP claim is discarded without a second POST or a queued retry" do
    with_item do |item|
      original_url = item.access_url
      claim_url = "https://example.com/private-setup-token"
      token = Base64.strict_encode64(claim_url)
      request = stub_request(:post, claim_url).to_raise(Net::ReadTimeout.new("Private claim failure"))
      claim = SimplefinItem::ConnectionUpdate.prepare(item, setup_token: token)
      diagnostics = []

      DebugLogEntry.stub(:capture, ->(**attributes) { diagnostics << attributes }) do
        VCR.turned_off do
          assert_no_enqueued_jobs do
            SimplefinConnectionUpdateJob.perform_now(family_id: item.family_id, claim_id: claim.id)
          end
        end
      end

      assert_equal original_url, item.reload.access_url
      assert claim.reload.uncertain?
      assert_empty item.syncs
      VCR.turned_off do
        assert_no_enqueued_jobs do
          SimplefinConnectionUpdateJob.perform_now(family_id: item.family_id, claim_id: claim.id)
        end
      end
      assert_requested request, times: 1
      assert_sanitized_failure(diagnostics, item, claim, "Provider::Simplefin::SimplefinError", token, claim_url)
    end
  end

  test "native ownership still propagates before claim or failure recovery" do
    with_item do |item|
      posted, token, = successful_claim
      claim = SimplefinItem::ConnectionUpdate.prepare(item, setup_token: token)
      ProviderMigrationControl.create!(family: item.family, provider_key: "simplefin",
        legacy_type: "SimplefinItem", legacy_id: item.id, state: "active")
      original_url = item.access_url
      DebugLogEntry.expects(:capture).never

      VCR.turned_off do
        assert_no_enqueued_jobs do
          assert_raises(Fence::OwnershipChanged) do
            SimplefinConnectionUpdateJob.perform_now(family_id: item.family_id, claim_id: claim.id)
          end
        end
      end

      assert_not_requested posted
      assert_equal original_url, item.reload.access_url
      assert claim.reload.prepared?
    end
  end

  test "old secret-bearing queue deliveries cannot manufacture a prepared claim" do
    with_item do |item|
      posted, token, = successful_claim
      SimplefinItem::ConnectionUpdate.expects(:prepare).never
      SimplefinItem::ConnectionUpdate.expects(:perform).never
      before = item.attributes

      assert_no_difference "ProviderCredentialClaim.count" do
        assert_no_enqueued_jobs do
          assert_raises(Fence::OwnershipChanged) do
            SimplefinConnectionUpdateJob.perform_now(family_id: item.family_id,
              old_simplefin_item_id: item.id, setup_token: token)
          end
        end
      end

      assert_not_requested posted
      assert_equal before, item.reload.attributes
    end
  end

  private
    def successful_claim
      claim_url = "https://example.com/private-setup-token"
      new_url = "https://access-user:access-secret@example.com/reconnected"
      [ stub_request(:post, claim_url).to_return(status: 200, body: new_url),
        Base64.strict_encode64(claim_url), new_url ]
    end

    def assert_sanitized_failure(diagnostics, item, claim, error_class, *secrets)
      diagnostic = diagnostics.sole
      assert_equal item.family_id, diagnostic.fetch(:family).id
      assert_equal "simplefin", diagnostic.fetch(:provider_key)
      assert_equal({ item_id: item.id, claim_id: claim.id, error_class: error_class }, diagnostic.fetch(:metadata))
      text = diagnostic.slice(:message, :metadata).inspect
      secrets.each { |secret| refute_includes text, secret }
      refute_includes text, "Private"
    end

    def with_item
      with_provider_encryption do
        family = Family.create!(name: "SimpleFIN reconnect retry")
        item = family.simplefin_items.create!(name: "SimpleFIN", access_url: "https://example.com/original")
        yield item
      ensure
        if family&.persisted?
          ProviderCredentialClaim.where(family_id: family.id).delete_all
          ProviderMigrationControl.where(family: family).delete_all
          item&.reload&.destroy!
          family.destroy!
        end
      end
    end
end
