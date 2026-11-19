require "test_helper"

class AutoMatchTransfersJobTest < ActiveJob::TestCase
  test "runs auto-match for the given family" do
    family = families(:empty)
    family.expects(:auto_match_transfers!).once

    AutoMatchTransfersJob.perform_now(family)
  end
end
