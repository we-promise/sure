require "test_helper"

class TransactionTimestampsControllerTest < ActionDispatch::IntegrationTest
  setup do
    travel_to Time.utc(2026, 9, 22, 12)
    sign_in @user = users(:family_admin)
    @user.family.update!(timezone: "Europe/Paris")
    @entry = entries(:transaction)
  end

  test "creates with optional local time without altering accounting date" do
    assert_difference "Entry.count", 1 do
      post transactions_url, params: { entry: {
        account_id: @entry.account_id, name: "Timestamped purchase", date: "2026-09-18",
        amount: 12, currency: "USD", entryable_type: "Transaction", transacted_at_local: "2026-09-17T16:48:50",
        entryable_attributes: { category_id: categories(:food_and_drink).id }
      } }
    end
    assert_response :redirect
    created = @entry.account.entries.find_by!(name: "Timestamped purchase")
    assert_equal Time.utc(2026, 9, 17, 14, 48, 50), created.transacted_at
    assert_equal Date.new(2026, 9, 18), created.date
    assert created.locked?(:transacted_at)
  end

  test "updates and clears time while unrelated edits preserve it" do
    patch transaction_url(@entry), params: { entry: { transacted_at_local: "2026-09-17T16:48:50.123456" } }, as: :turbo_stream
    assert_response :success
    assert_select "turbo-stream[target='timestamp_#{dom_id(@entry)}']", count: 0
    assert_select "turbo-stream[target='#{dom_id(@entry)}']"
    expected = Time.iso8601("2026-09-17T14:48:50.123456Z")
    assert_equal expected, @entry.reload.transacted_at

    patch transaction_url(@entry), params: { entry: { notes: "A note" } }
    assert_equal expected, @entry.reload.transacted_at

    patch transaction_url(@entry), params: { entry: { transacted_at_local: "" } }
    assert_nil @entry.reload.transacted_at
    assert @entry.locked?(:transacted_at)
  end

  test "editing another field does not lock an unknown time" do
    patch transaction_url(@entry), params: { entry: { notes: "A note", transacted_at_local: "" } }

    assert_response :redirect
    assert_nil @entry.reload.transacted_at
    assert_not @entry.locked?(:transacted_at)
  end

  test "editing another field does not lock an unchanged imported time" do
    original = Time.iso8601("2026-09-17T14:48:50.123456Z")
    @entry.update!(transacted_at: original)
    assert_not @entry.locked?(:transacted_at)

    patch transaction_url(@entry), params: { entry: {
      notes: "Updated note", transacted_at_local: @entry.transacted_at_local
    } }

    assert_response :redirect
    assert_equal original, @entry.reload.transacted_at
    assert_not @entry.locked?(:transacted_at)
  end

  test "invalid time renders an error without saving" do
    patch transaction_url(@entry), params: { entry: { transacted_at_local: "2026-02-30T12:00" } }
    assert_response :unprocessable_entity
    assert_includes response.body, "must be a valid date and time"
    assert_nil @entry.reload.transacted_at
  end

  test "lowercase UTC suffix updates an instant even when it matches the previous local clock" do
    @entry.update!(transacted_at: Time.utc(2026, 9, 17, 9))
    accounting_date = @entry.date

    patch transaction_url(@entry), params: { entry: { transacted_at_local: "2026-09-17t11:00:00z " } }

    assert_response :redirect
    assert_equal Time.utc(2026, 9, 17, 11), @entry.reload.transacted_at
    assert_equal accounting_date, @entry.date
    assert @entry.locked?(:transacted_at)
  end

  test "read-only user cannot change occurrence time" do
    sign_in users(:family_member)
    entry = entries(:transfer_in)
    entry.update!(transacted_at: Time.utc(2026, 9, 17, 9))
    original = entry.transacted_at
    patch transaction_url(entry), params: { entry: { transacted_at_local: "2026-09-17T16:48:50" } }
    assert_equal original, entry.reload.transacted_at
  end

  test "timestamp editor and tooltip retain seconds" do
    @entry.update!(transacted_at: Time.utc(2026, 9, 17, 14, 48, 50))
    get transaction_url(@entry)
    assert_response :success
    assert_select "input[type='datetime-local'][name='entry[transacted_at_local]'][value='2026-09-17T16:48:50'][step='1']"
    get transactions_url
    tooltip_id = nil
    assert_select "a[data-clickable-row-target='link']", text: @entry.name do |links|
      assert_nil links.first["title"]
      tooltip_id = links.first["aria-describedby"]
      assert tooltip_id.present?
    end
    assert_select "##{tooltip_id}[role='tooltip']", text: "2026-09-17T16:48:50+02:00"
    assert_select "[data-controller='DS--tooltip'] > span > a[aria-describedby='#{tooltip_id}']", text: @entry.name
    assert_select "button a[aria-describedby='#{tooltip_id}']", count: 0
  end
end
