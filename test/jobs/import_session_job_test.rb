require "test_helper"

class ImportSessionJobTest < ActiveJob::TestCase
  test "raises when import session is missing" do
    error = assert_raises(ArgumentError) do
      ImportSessionJob.perform_now(nil)
    end

    assert_equal "ImportSessionJob requires an import_session", error.message
  end

  test "publishes import session" do
    import_session = families(:empty).import_sessions.create!

    import_session.expects(:publish).once

    ImportSessionJob.perform_now(import_session)
  end
end
