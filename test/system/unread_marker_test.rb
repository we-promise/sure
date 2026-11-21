require "application_system_test_case"

class UnreadMarkerTest < ApplicationSystemTestCase
  include EntriesTestHelper

  test "a list served from a hover prefetch marks its rows read once displayed" do
    user = users(:family_admin)
    user.update_column(:transactions_read_before, 1.hour.ago)
    entry = create_transaction(account: accounts(:depository), external_id: "prefetched", source: "simplefin", name: "Prefetched row")
    # A real prefetch cannot be triggered from Capybara; render the prefetch
    # variant of the response directly instead.
    TransactionsController.any_instance.stubs(:prefetch_request?).returns(true)

    sign_in user
    visit transactions_path
    assert_text "Prefetched row"

    assert_eventually { !user.unread_entries.exists?(id: entry.id) }
  end

  private
    def assert_eventually(timeout: Capybara.default_max_wait_time)
      deadline = Time.current + timeout
      sleep 0.1 until yield || Time.current > deadline
      assert yield
    end
end
