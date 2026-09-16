require "test_helper"
require "timeout"
require_relative "../support/provider_ingestion_test_helper"

class SophtronLegacyJobsTest < ActiveJob::TestCase
  include ProviderIngestionTestHelper
  self.use_transactional_tests = false

  Fence = Provider::AccountData::LegacyWriterFence

  test "polling and initial load cannot mutate or reenqueue a quiescing or native source" do
    with_item do |item, account|
      control = ProviderMigrationControl.create!(family: item.family, provider_key: "sophtron",
        legacy_type: "SophtronItem", legacy_id: item.id, state: "quiescing")
      SophtronItem.any_instance.expects(:sophtron_provider).never
      before_attributes = item.reload.attributes

      %w[quiescing active retired].each do |state|
        control.update!(state: state)
        assert_no_enqueued_jobs do
          assert_raises(Fence::OwnershipChanged) { SophtronRefreshPollJob.perform_now(account, job_id: "old-job") }
          assert_raises(Fence::OwnershipChanged) { SophtronInitialLoadJob.perform_now(item) }
        end
        assert_equal before_attributes, item.reload.attributes
      end
    end
  end

  test "polling builds its client from the admitted current credentials and holds the permit across HTTP" do
    with_item do |item, account|
      # The argument's cached parent intentionally predates this credential edit.
      account.sophtron_item = item
      SophtronItem.find(item.id).update!(user_id: "current-user")
      provider = mock("fresh Sophtron client")
      Provider::Sophtron.expects(:new).with("current-user", item.access_key, base_url: item.effective_base_url).returns(provider)
      provider.expects(:get_job_information).with do |job_id|
        assert_equal "refresh-job", job_id
        assert_equal 0, ApplicationRecord.connection.open_transactions
        assert_equal :busy, try_drain_in_another_session(item)
        true
      end.returns({ LastStatus: "Started" })

      assert_enqueued_with(job: SophtronRefreshPollJob) do
        SophtronRefreshPollJob.perform_now(account, job_id: "refresh-job", attempts_remaining: 2)
      end
      assert_equal :drained, try_drain_in_another_session(item)
      assert_equal "developer-user", item.user_id
      assert_equal "Started", item.reload.job_status
    end
  end

  test "polling rejects a foreign or cancelled sync before calling the provider" do
    with_item do |item, account|
      foreign = item.family.syncs.create!
      cancelled = item.syncs.create!(cancel_requested_at: Time.current)
      SophtronItem.any_instance.expects(:sophtron_provider).never

      assert_no_enqueued_jobs do
        [ foreign, cancelled ].each do |sync|
          assert_raises(Fence::OwnershipChanged) do
            SophtronRefreshPollJob.perform_now(account, job_id: "refresh-job", sync: sync)
          end
        end
      end
    ensure
      foreign&.destroy!
    end
  end

  test "cancellation while polling prevents status publication and follow-up scheduling" do
    with_item do |item, account|
      sync = item.syncs.create!(status: "completed")
      before_attributes = item.reload.attributes
      provider = mock("Sophtron client")
      SophtronItem.any_instance.stubs(:sophtron_provider).returns(provider)
      provider.expects(:get_job_information).with do |_job_id|
        sync.update_columns(cancel_requested_at: Time.current)
        true
      end.returns({ LastStatus: "Started" })

      assert_no_enqueued_jobs do
        assert_raises(Fence::OwnershipChanged) do
          SophtronRefreshPollJob.perform_now(account, job_id: "refresh-job", sync: sync)
        end
      end
      assert_equal before_attributes, item.reload.attributes
    end
  end

  test "initial load waits under its permit and schedules from a fresh source" do
    with_item do |item, _account|
      sync = item.syncs.create!(status: "syncing")
      assert_enqueued_with(job: SophtronInitialLoadJob) do
        SophtronInitialLoadJob.perform_now(item, attempts_remaining: 1)
      end
      sync.update_columns(status: "completed")

      assert_enqueued_with(job: SyncJob) do
        SophtronInitialLoadJob.perform_now(item)
      end
    end
  end

  test "a cross-family financial link is refused before polling" do
    with_item do |item, account|
      other_account = Account.create!(family: families(:empty), name: "Foreign financial account",
        currency: "USD", balance: 0, accountable: Depository.create!)
      AccountProvider.create!(account: other_account, provider: account)
      SophtronItem.any_instance.expects(:sophtron_provider).never

      assert_raises(Fence::OwnershipChanged) { SophtronRefreshPollJob.perform_now(account, job_id: "refresh-job") }
    ensure
      other_account&.destroy!
    end
  end

  private
    def with_item
      with_provider_encryption do
        item = SophtronItem.create!(family: families(:dylan_family), name: "Fenced refresh",
          user_id: "developer-user", access_key: Base64.strict_encode64("test-key"),
          customer_id: "customer", user_institution_id: "institution")
        account = item.sophtron_accounts.create!(account_id: "remote-account", name: "Checking",
          currency: "USD", raw_transactions_payload: [])
        begin
          yield item, account
        ensure
          ProviderMigrationControl.where(legacy_type: "SophtronItem", legacy_id: item.id).destroy_all
          item.reload.destroy!
        end
      end
    end

    def try_drain_in_another_session(item)
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
