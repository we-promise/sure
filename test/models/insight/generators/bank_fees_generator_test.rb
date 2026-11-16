require "test_helper"

class Insight::Generators::BankFeesGeneratorTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    travel_to Date.new(2026, 11, 16)

    @family = families(:dylan_family)
    # `depository` is shared with family_member; `connected` is private to
    # family_admin; `investment` is private too unless a test shares it.
    @checking = accounts(:depository)
    @fees = @family.categories.create!(name: I18n.t("models.category.defaults.fees"), color: "#6b7280", lucide_icon: "receipt")
    # Every account has history from before both windows unless a test says
    # otherwise, so "no fees before" means the account was there to charge them.
    @family.accounts.each { |account| history_since(account, 200.days.ago) }
  end

  test "flags fees at or above the minimum on an account every member can see" do
    fee(@checking, 12, 70.days.ago)
    fee(@checking, 12, 40.days.ago)
    fee(@checking, 12, 10.days.ago)
    fee(@checking, 5, 120.days.ago) # prior window: this is not a new fee

    insight = generate_for(@checking)

    assert_equal "bank_fees", insight.insight_type
    assert_equal "bank_fees.recurring", insight.template_key
    assert_equal "low", insight.priority
    assert_equal "$36.00", insight.facts[:amount]
    assert_equal "Checking Account", insight.facts[:account]
    assert_equal 3, insight.facts[:count]
    assert_equal "bank_fees:#{@checking.id}", insight.dedup_key
    assert_equal (Date.current - 90), insight.period_start
    assert_equal Date.current, insight.period_end
    assert_equal "Checking Account had $36.00 in fees over the last 90 days.",
      Insight::BodyWriter.new.write(insight)
  end

  test "stays quiet below the minimum when the account already charged fees before" do
    fee(@checking, 4, 20.days.ago)
    fee(@checking, 4, 100.days.ago)

    assert_nil generate_for(@checking)
  end

  test "a first fee is flagged below the minimum, at medium priority" do
    fee(@checking, 3, 5.days.ago)

    insight = generate_for(@checking)

    assert_equal "bank_fees.new", insight.template_key
    assert_equal "medium", insight.priority
    assert insight.metadata[:new]
  end

  test "a small fee on an account without history from before both windows is not a first fee" do
    Entry.where(account: @checking).delete_all
    history_since(@checking, 120.days.ago)
    fee(@checking, 3, 5.days.ago)

    assert_nil generate_for(@checking), "an account that did not exist 180 days ago cannot prove it charged no fees then"

    fee(@checking, 9, 4.days.ago)
    assert_equal "bank_fees.recurring", generate_for(@checking).template_key, "the minimum still applies"
  end

  test "the card stays the same across quarters and comes back only with a new fee" do
    fee(@checking, 12, 20.days.ago)
    fee(@checking, 1, 100.days.ago)
    before = generate_for(@checking)

    travel_to Date.new(2027, 1, 2)
    after = generate_for(@checking)

    assert_equal before.dedup_key, after.dedup_key
    assert_equal before.metadata, after.metadata

    fee(@checking, 12, Date.current)
    assert_not_equal before.metadata, generate_for(@checking).metadata
  end

  test "fees that only fall in the prior window are not flagged" do
    fee(@checking, 50, 100.days.ago)

    assert_nil generate_for(@checking)
  end

  test "a refunded fee nets out of the total" do
    fee(@checking, 15, 30.days.ago)
    fee(@checking, -15, 25.days.ago)
    fee(@checking, 4, 100.days.ago)

    assert_nil generate_for(@checking)
  end

  test "subcategories of Fees count, and so does the Fees category named in the family's locale" do
    @family.update!(locale: "es")
    @fees.update!(name: I18n.t("models.category.defaults.fees", locale: :es))
    overdraft = @family.categories.create!(name: "Overdraft", parent: @fees, color: "#6b7280", lucide_icon: "receipt")
    fee(@checking, 8, 30.days.ago, category: overdraft)
    fee(@checking, 8, 20.days.ago)
    fee(@checking, 1, 100.days.ago)

    assert_equal "$16.00", generate_for(@checking).facts[:amount]
  end

  test "a category named Fees in a locale the family does not use is not the Fees category" do
    @fees.update!(name: I18n.t("models.category.defaults.fees", locale: :fr))
    fee(@checking, 40, 10.days.ago)

    assert_nil generate_for(@checking)
  end

  test "excluded, pending, transfer-kind and split-parent rows are ignored" do
    fee(@checking, 1, 100.days.ago)
    fee(@checking, 40, 10.days.ago).update!(excluded: true)
    pending = fee(@checking, 40, 9.days.ago)
    pending.entryable.update!(extra: { "plaid" => { "pending" => true } })
    create_transaction(account: @checking, amount: 40, date: 8.days.ago.to_date, category: @fees, kind: "funds_movement")
    parent = fee(@checking, 40, 7.days.ago)
    Entry.create!(account: @checking, parent_entry: parent, name: "Part", date: parent.date, currency: "USD", amount: 40,
                  entryable: Transaction.new(category: categories(:food_and_drink)))

    assert_nil generate_for(@checking)
  end

  test "investment accounts are left out even when shared with everyone" do
    investment = accounts(:investment)
    AccountShare.create!(account: investment, user: users(:family_member), permission: :read_only)
    fee(investment, 25, 10.days.ago)

    assert_nil generate_for(investment)
  end

  test "an account private to one member is left out of the shared feed" do
    private_account = accounts(:connected)
    fee(private_account, 25, 10.days.ago)

    assert_nil generate_for(private_account)

    users(:family_member).update_columns(active: false)
    assert_not_nil generate_for(private_account), "an inactive member does not hide an account"
  end

  test "a fee rolling out of the window does not change the material metadata" do
    fee(@checking, 12, 85.days.ago)
    latest = fee(@checking, 12, 10.days.ago)
    fee(@checking, 1, 100.days.ago)
    before = generate_for(@checking).metadata

    travel 10.days
    after = generate_for(@checking).metadata

    assert_equal before, after
    assert_equal latest.date.iso8601, after[:last_fee_on]
  end

  private
    def fee(account, amount, date, category: @fees)
      create_transaction(account: account, amount: amount, date: date.to_date, name: "Maintenance fee", category: category)
    end

    def history_since(account, date)
      create_transaction(account: account, amount: 1, date: date.to_date, name: "Opening activity")
    end

    def generate_for(account)
      Insight::Generators::BankFeesGenerator.new(@family).generate.find { |insight| insight.metadata[:account_id] == account.id }
    end
end
