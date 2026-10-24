require "test_helper"

class LoanRenderingLockTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false

  setup do
    @user = users(:family_admin).dup
    @user.email = "loan-render-#{SecureRandom.uuid}@example.com"
    @user.password = user_password_test
    @user.save!
    sign_in @user
    @account = @user.family.accounts.create!(
      name: "Loan rendering", balance: 100_000, currency: "USD",
      accountable: Loan.new(rate_type: "variable", interest_rate: 6, start_date: Date.new(2024, 1, 1),
                            variable_rate_schedule: { "2026-01-01" => "7" })
    )
  end

  teardown do
    @account&.destroy!
    @plaid_account&.destroy!
    @user&.destroy!
  end

  test "a balance edit compares with the account committed before the lock" do
    snapshot = @account.loan.rate_schedule_snapshot

    with_concurrent_account_update(balance: 90_000, currency: "EUR", notes: "Provider notes",
                                   locked_attributes: { "notes" => Time.current.iso8601 }) do
      patch loan_path(@account), params: { account: {
        name: "Edited loan", balance: 100_000, accountable_attributes: {
          rate_schedule_snapshot: snapshot,
          rate_changes: [ { effective_date: "2026-03-01", rate: "9" } ]
        }
      } }
    end

    assert_redirected_to account_path(@account)
    assert_equal 100_000, @account.reload.balance
    assert_equal "Edited loan", @account.name
    assert_equal "Provider notes", @account.notes
    assert @account.locked?("notes")
    assert_equal "EUR", @account.currency
    assert_equal [ "EUR" ], @account.entries.distinct.pluck(:currency)
    assert_equal({ "2026-02-01" => "8", "2026-03-01" => "9.0" }, @account.loan.variable_rate_schedule)
  end

  test "a balance already committed before the lock does not create another valuation" do
    assert_no_difference "Entry.count" do
      with_concurrent_account_update(balance: 90_000) do
        patch loan_path(@account), params: { account: { name: "Edited loan", balance: 90_000 } }
      end
    end

    assert_redirected_to account_path(@account)
    assert_equal 90_000, @account.reload.balance
    assert_equal "Edited loan", @account.name
  end

  test "a failed balance edit preserves the concurrent account and schedule on retry" do
    snapshot = @account.loan.rate_schedule_snapshot
    assert_no_difference "Entry.count" do
      with_concurrent_account_update(balance: 90_000, notes: "Provider notes") do
        patch loan_path(@account), params: { account: {
          name: "Rejected name", balance: 100_000, accountable_attributes: {
            rate_schedule_snapshot: snapshot,
            rate_changes: [ { effective_date: "", rate: "9" } ]
          }
        } }
      end
    end

    assert_response :unprocessable_entity
    assert_equal 90_000, @account.reload.balance
    assert_equal "Loan rendering", @account.name
    assert_equal "Provider notes", @account.notes
    expected = { "2026-01-01" => "7", "2026-02-01" => "8" }
    assert_equal expected, @account.loan.variable_rate_schedule
    snapshot = css_select("input[name='account[accountable_attributes][rate_schedule_snapshot]']").first["value"]
    assert_equal expected, JSON.parse(snapshot)

    patch loan_path(@account), params: { account: { balance: 90_000, accountable_attributes: {
      rate_schedule_snapshot: snapshot,
      rate_changes: expected.map { |date, rate| { effective_date: date, rate: rate } }
    } } }

    assert_redirected_to account_path(@account)
    assert_equal 90_000, @account.reload.balance
    assert_equal expected, @account.loan.variable_rate_schedule
  end

  test "a linked loan rolls back a rejected balance edit and saves its anchor on retry" do
    @plaid_account = PlaidAccount.create!(
      plaid_item: plaid_items(:one), plaid_id: SecureRandom.uuid, name: "Linked loan", currency: "USD",
      current_balance: 100_000, plaid_type: "loan", plaid_subtype: "mortgage"
    )
    @account.account_providers.create!(provider: @plaid_account)
    assert @account.reload.linked?
    snapshot = @account.loan.rate_schedule_snapshot

    assert_no_difference "Entry.count" do
      with_concurrent_account_update(balance: 90_000, currency: "EUR") do
        patch loan_path(@account), params: { account: { balance: 100_000, accountable_attributes: {
          rate_schedule_snapshot: snapshot, rate_changes: [ { effective_date: "", rate: "9" } ]
        } } }
      end
    end

    assert_response :unprocessable_entity
    assert_equal 90_000, @account.reload.balance
    assert_empty @account.valuations.current_anchor
    snapshot = css_select("input[name='account[accountable_attributes][rate_schedule_snapshot]']").first["value"]

    patch loan_path(@account), params: { account: { name: "Linked edit", balance: 100_000, accountable_attributes: {
      rate_schedule_snapshot: snapshot,
      rate_changes: [ { effective_date: "2026-01-01", rate: "7" }, { effective_date: "2026-02-01", rate: "8" } ]
    } } }

    assert_redirected_to account_path(@account)
    assert_equal 100_000, @account.reload.balance
    assert_equal "Linked edit", @account.name
    assert_equal 1, @account.valuations.current_anchor.count
    anchor = @account.valuations.current_anchor.first.entry
    assert_equal 100_000, anchor.amount
    assert_equal "EUR", anchor.currency
    assert_equal({ "2026-01-01" => "7", "2026-02-01" => "8" }, @account.loan.variable_rate_schedule)
  end

  test "all rejected update forms render after account and loan locks are released" do
    submissions = [
      { rate_changes: [] },
      { rate_schedule_snapshot: "[]", rate_changes: [] },
      { rate_schedule_snapshot: @account.loan.rate_schedule_snapshot, rate_changes: [ { effective_date: "", rate: "9" } ] }
    ]
    submissions.each do |attributes|
      rendered = 0
      subscriber = lambda do |event|
        next unless event.payload[:identifier].to_s.end_with?("/loans/edit.html.erb")

        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do |connection|
            connection.transaction do
              Account.where(id: @account.id).lock("FOR UPDATE NOWAIT").pick(:id)
              Loan.where(id: @account.accountable_id).lock("FOR UPDATE NOWAIT").pick(:id)
            end
          end
        end.value
        rendered += 1
      end

      ActiveSupport::Notifications.subscribed(subscriber, "render_template.action_view") do
        patch loan_path(@account), params: { account: { accountable_attributes: attributes } }
      end

      assert_response :unprocessable_entity
      assert_equal 1, rendered
    end
  end

  private
    def with_concurrent_account_update(attributes)
      account_id = @account.id
      test_case = self
      callback = lambda do |controller|
        loaded = controller.instance_variable_get(:@account)
        test_case.assert_equal 100_000, loaded.balance
        loaded.accountable
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            account = Account.find(account_id)
            account.update!(attributes)
            account.loan.enrich_attributes(
              { variable_rate_schedule: { "2026-01-01" => "7", "2026-02-01" => "8" } }, source: "redbark"
            )
          end
        end.value
      end
      LoansController.before_action(callback, only: :update)
      yield
    ensure
      LoansController.skip_before_action(callback)
    end
end
