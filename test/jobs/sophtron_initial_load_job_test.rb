require "test_helper"

class SophtronInitialLoadJobTest < ActiveJob::TestCase
  test "a job queued before follow-ups were built in still requests a sync" do
    sophtron_item = families(:dylan_family).sophtron_items.create!(
      name: "Sophtron", user_id: "developer-user", access_key: Base64.strict_encode64("secret-key")
    )
    sophtron_item.expects(:sync_later).once

    SophtronInitialLoadJob.perform_now(sophtron_item, attempts_remaining: 30)
  end
end
