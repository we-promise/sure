require "test_helper"

class ImportJobTest < ActiveJob::TestCase
  test "import is published" do
    import = imports(:transaction)
    import.expects(:publish).with(publish_token: nil).once

    ImportJob.perform_now(import)
  end

  test "import is published with its claim token" do
    import = imports(:transaction)
    import.expects(:publish).with(publish_token: "publish-token").once

    ImportJob.perform_now(import, publish_token: "publish-token")
  end
end
