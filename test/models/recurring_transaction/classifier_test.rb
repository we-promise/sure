require "test_helper"

class RecurringTransaction::ClassifierTest < ActiveSupport::TestCase
  Classifier = RecurringTransaction::Classifier

  def setup
    @family = families(:dylan_family)
    @depository = accounts(:depository)
    @credit_card = accounts(:credit_card)
  end

  test "known services classify as subscriptions with autopay on" do
    result = Classifier.classify(name: "Netflix.com", entries: entries_of(15.99, 15.99), account: @depository)

    assert_equal "subscription", result.bill_type
    assert result.autopay
  end

  test "utility and telecom wording classifies as a bill even when flat" do
    result = Classifier.classify(name: "XFINITY INTERNET", entries: entries_of(89.99, 89.99), account: @credit_card)

    assert_equal "bill", result.bill_type
    assert_not result.autopay
  end

  test "ach and billpay descriptors are push payments, not subscriptions" do
    result = Classifier.classify(name: "WATSON PROPERTY WEB PMT", entries: entries_of(537.50, 537.50), account: @depository)

    assert_equal "bill", result.bill_type
  end

  test "a flat modest card charge with no name signal reads as a subscription" do
    result = Classifier.classify(name: "SOMEOBSCURESERVICE", entries: entries_of(9.99, 9.99), account: @credit_card)

    assert_equal "subscription", result.bill_type
  end

  test "varying amounts break the card-charge heuristic" do
    result = Classifier.classify(name: "SOMEOBSCURESERVICE", entries: entries_of(42.17, 39.80), account: @credit_card)

    assert_equal "bill", result.bill_type
  end

  test "interest charges never read as subscriptions someone chose" do
    result = Classifier.classify(name: "Interest Charge", entries: entries_of(2.14, 2.14), account: @credit_card)

    assert_equal "bill", result.bill_type
  end

  test "the series inherits the cluster's most common category" do
    food = categories(:food_and_drink)
    tagged = entries_of(12, 12, 12)
    tagged.first(2).each { |entry| entry.entryable.update!(category: food) }

    result = Classifier.classify(name: "MYSTERY BOX", entries: tagged, account: @depository)

    assert_equal food.id, result.category_id
  end

  test "detection creates classified suggestions" do
    @family.recurring_transactions.destroy_all
    [ 0, 1, 2 ].each do |months_ago|
      @credit_card.entries.create!(
        date: months_ago.months.ago.beginning_of_month + 7.days,
        amount: 15.99, currency: "USD", name: "SPOTIFY USA",
        entryable: Transaction.new
      )
    end

    RecurringTransaction::Identifier.new(@family).identify_recurring_patterns

    created = @family.recurring_transactions.find_by(name: "SPOTIFY USA")
    assert_equal "subscription", created.bill_type
    assert created.autopay
    assert_equal "suggested", created.status
  end

  private
    def entries_of(*amounts)
      amounts.map.with_index do |amount, index|
        @depository.entries.create!(
          date: index.months.ago.to_date,
          amount: amount,
          currency: "USD",
          name: "classifier test entry #{index}",
          entryable: Transaction.new
        )
      end
    end
end
