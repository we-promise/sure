require "test_helper"

class DirectaHistorySyncJobTest < ActiveJob::TestCase
  setup do
    ActiveRecordEncryptionConfig.stubs(:explicitly_configured?).returns(true)
    @item = DirectaItem.create!(
      family: families(:dylan_family),
      owner: users(:family_admin),
      broker_account: "00123",
      account_identity: "verified-account-123",
      multi_token: "synthetic-multi-token",
      mono_token: "synthetic-mono-token",
      status: :connected,
      connection_generation: 3
    )
  end

  test "loads an item id and delegates to the Directa history syncer" do
    syncer = mock("Directa history syncer")
    DirectaItem::HistorySyncer.expects(:new).with(@item).returns(syncer)
    syncer.expects(:perform).once

    DirectaHistorySyncJob.perform_now(@item.id)
  end

  test "accepts a Directa item through Active Job serialization" do
    syncer = mock("Directa history syncer")
    DirectaItem::HistorySyncer.expects(:new).with(@item).returns(syncer)
    syncer.expects(:perform).once

    perform_enqueued_jobs { DirectaHistorySyncJob.perform_later(@item) }
  end

  test "ignores an item id that no longer exists" do
    DirectaItem::HistorySyncer.expects(:new).never

    DirectaHistorySyncJob.perform_now(SecureRandom.uuid)
  end
end
