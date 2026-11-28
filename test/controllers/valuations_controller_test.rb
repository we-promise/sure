require "test_helper"

class ValuationsControllerTest < ActionDispatch::IntegrationTest
  include EntryableResourceInterfaceTest

  setup do
    sign_in @user = users(:family_admin)
    @entry = entries(:valuation)
  end

  test "can create reconciliation" do
    account = accounts(:investment)

    assert_difference [ "Entry.count", "Valuation.count" ], 1 do
      post valuations_url, params: {
        entry: {
          amount: account.balance + 100,
          date: Date.current.to_s,
          account_id: account.id
        }
      }
    end

    created_entry = Entry.order(created_at: :desc).first
    assert_equal "Manual value update", created_entry.name
    assert_equal Date.current, created_entry.date
    assert_equal account.balance + 100, created_entry.amount_money.to_f

    assert_enqueued_with job: SyncJob

    assert_redirected_to account_url(created_entry.account)
  end

  test "updates entry with basic attributes" do
    assert_no_difference [ "Entry.count", "Valuation.count" ] do
      patch valuation_url(@entry), params: {
        entry: {
          amount: 22000,
          date: Date.current,
          notes: "Test notes"
        }
      }
    end

    assert_enqueued_with job: SyncJob

    assert_redirected_to account_url(@entry.account)

    @entry.reload
    assert_equal 22000, @entry.amount
    assert_equal "Test notes", @entry.notes
  end

  test "a confirmed value update reloads the page, closing the confirmation dialog" do
    patch valuation_url(@entry), params: { entry: { amount: 22000, date: @entry.date } }, as: :turbo_stream,
      headers: { "Referer" => account_url(@entry.account) }

    assert_response :success
    assert_select "turbo-stream[action=redirect][target=?]", account_url(@entry.account)
    assert_equal 22000, @entry.reload.amount
  end

  test "a confirmed date change is saved and reloads the page" do
    new_date = @entry.date - 3.days

    patch valuation_url(@entry), params: { entry: { amount: @entry.amount, date: new_date } }, as: :turbo_stream,
      headers: { "Referer" => account_url(@entry.account) }

    assert_select "turbo-stream[action=redirect][target=?]", account_url(@entry.account)
    assert_equal new_date, @entry.reload.date
  end

  test "a confirmed value update without a Referer reloads the account page" do
    patch valuation_url(@entry), params: { entry: { amount: 22000, date: @entry.date } }, as: :turbo_stream

    assert_response :success
    assert_select "turbo-stream[action=redirect][target=?]", account_path(@entry.account)
  end

  test "saving notes keeps the drawer open and redraws it in place" do
    patch valuation_url(@entry), params: { entry: { notes: "Checked against the statement" } }, as: :turbo_stream

    assert_response :success
    assert_select "turbo-stream[action=replace][target=?]", dom_id(@entry, :header)
    assert_select "turbo-stream[action=redirect]", count: 0
    assert_equal "Checked against the statement", @entry.reload.notes
  end

  test "confirm_create with blank amount returns unprocessable entity" do
    account = accounts(:investment)

    post confirm_create_valuations_url, params: {
      entry: {
        amount: "",
        date: Date.current.to_s,
        account_id: account.id
      }
    }

    assert_response :unprocessable_entity
    assert_match I18n.t("valuations.errors.amount_required"), response.body
  end

  test "confirm_update with blank amount returns unprocessable entity" do
    post confirm_update_valuation_url(@entry), params: {
      entry: {
        amount: "",
        date: Date.current.to_s
      }
    }

    assert_response :unprocessable_entity
    assert_match I18n.t("valuations.errors.amount_required"), response.body
  end

  test "clearing a note saves it cleared" do
    @entry.update!(notes: "Old note")

    patch valuation_url(@entry), params: { entry: { notes: "" } }

    assert_redirected_to account_url(@entry.account)
    assert_nil @entry.reload.notes
  end

  test "a balance update without the notes field keeps the note" do
    @entry.update!(notes: "Keep me")

    patch valuation_url(@entry), params: { entry: { amount: 22000, date: Date.current } }

    assert_redirected_to account_url(@entry.account)
    @entry.reload
    assert_equal 22000, @entry.amount
    assert_equal "Keep me", @entry.notes
  end
end
