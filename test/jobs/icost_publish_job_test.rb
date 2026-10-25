require "test_helper"

class IcostPublishJobTest < ActiveJob::TestCase
  test "background publication retains owner authorization" do
    batch = IcostImport.new
    user = users(:family_admin)
    batch.expects(:process!).with(user: user).once
    IcostPublishJob.perform_now(batch, user)
  end
end
