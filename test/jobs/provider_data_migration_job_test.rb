require "test_helper"

class ProviderDataMigrationJobTest < ActiveJob::TestCase
  setup do
    @item = UpItem.create!(family: families(:dylan_family), name: "Migration source", access_token: "test-up-token")
  end

  test "copying schedules the next bounded batch for the same source and tenant" do
    item = @item
    arguments = { provider_key: "up", legacy_item_id: item.id, family_id: item.family_id }
    copier = mock("migration copier")
    Provider::AccountData::MigrationCopier.expects(:new).with(provider_key: "up", legacy_item_id: item.id).returns(copier)
    copier.expects(:run).returns(stub(copying?: true))

    assert_enqueued_with(job: ProviderDataMigrationJob, args: [ arguments ]) do
      ProviderDataMigrationJob.perform_now(**arguments)
    end
  end

  test "verified shadow does not enqueue activation or another copy" do
    item = @item
    copier = mock("migration copier")
    Provider::AccountData::MigrationCopier.expects(:new).with(provider_key: "up", legacy_item_id: item.id).returns(copier)
    copier.expects(:run).returns(stub(copying?: false))

    assert_no_enqueued_jobs do
      ProviderDataMigrationJob.perform_now(provider_key: "up", legacy_item_id: item.id, family_id: item.family_id)
    end
  end

  test "wrong tenant cannot start a copy" do
    item = @item
    Provider::AccountData::MigrationCopier.expects(:new).never

    assert_raises(ArgumentError) do
      ProviderDataMigrationJob.perform_now(provider_key: "up", legacy_item_id: item.id, family_id: families(:empty).id)
    end
  end
end
