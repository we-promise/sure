require "test_helper"

class FinecoHistorySyncJobTest < ActiveJob::TestCase
  setup do
    ActiveRecordEncryptionConfig.stubs(:explicitly_configured?).returns(true)
    Provider::Fineco.stubs(:verified_identity_contract?).returns(true)
    @item = FinecoItem.create!(
      family: families(:dylan_family),
      owner: users(:family_admin),
      gsessionid: "synthetic-session",
      account_index: "2",
      dossier_index: "11",
      bank_account_number: "SYNTHETIC-ACCOUNT",
      dossier_identity: Digest::SHA256.hexdigest("synthetic-dossier"),
      captured_at: Time.current
    )
  end

  test "loads an item id and delegates the history sync" do
    syncer = mock
    FinecoItem::HistorySyncer.expects(:new).with(@item).returns(syncer)
    syncer.expects(:perform).once

    FinecoHistorySyncJob.perform_now(@item.id)
  end

  test "accepts an item through Active Job global id serialization" do
    syncer = mock
    FinecoItem::HistorySyncer.expects(:new).with(@item).returns(syncer)
    syncer.expects(:perform).once

    perform_enqueued_jobs do
      FinecoHistorySyncJob.perform_later(@item)
    end
  end

  test "ignores an item id that no longer exists" do
    FinecoItem::HistorySyncer.expects(:new).never

    FinecoHistorySyncJob.perform_now(SecureRandom.uuid)
  end
end
