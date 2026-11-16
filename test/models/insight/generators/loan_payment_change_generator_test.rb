require "test_helper"

class Insight::Generators::LoanPaymentChangeGeneratorTest < ActiveSupport::TestCase
  setup do
    travel_to Date.new(2026, 11, 20)
    @family = families(:dylan_family)
    @account = accounts(:loan)
    # The fixture loan is private to the admin; most cases need it shared.
    @share = AccountShare.create!(account: @account, user: users(:family_member), permission: "read_only")
    @account.loan.update!(
      rate_type: "variable", interest_rate: 3.0, term_months: 300, initial_balance: 250_000,
      start_date: Date.new(2025, 12, 10), variable_rate_schedule: { "2026-12-10" => "4.5" }
    )
  end

  test "flags a recorded rate change that resizes the payment within 60 days" do
    insight = generate.sole
    payments = @account.loan.amortization_schedule.payments
    before = payments.find { |payment| payment.date == Date.new(2026, 11, 10) }.payment
    after = payments.find { |payment| payment.date == Date.new(2026, 12, 10) }.payment

    assert_equal "loan_payment_change", insight.insight_type
    assert_equal "loan_payment_change:#{@account.id}:2026-12-10", insight.dedup_key
    assert_equal "loan_payment_change.up", insight.template_key
    assert_equal({ account_id: @account.id, effective_on: "2026-12-10",
                   previous_payment: before.amount.to_f, new_payment: after.amount.to_f }, insight.metadata)
    assert_equal before.format, insight.facts[:previous_payment]
    assert_equal after.format, insight.facts[:new_payment]
    assert_equal @account.name, insight.facts[:account]
  end

  test "stops emitting the change once its date has passed, so the job expires it" do
    travel_to Date.new(2026, 12, 11)

    assert_empty generate
  end

  test "ignores a change further out than 60 days" do
    @account.loan.update!(variable_rate_schedule: { "2027-02-10" => "4.5" })

    assert_empty generate
  end

  test "the window includes day 60 and excludes day 61" do
    stub_payments([ 1_000, Date.new(2026, 11, 10) ], [ 1_100, Date.new(2027, 1, 19) ], [ 1_100, Date.new(2027, 2, 19) ])
    assert_equal "2027-01-19", generate.sole.metadata[:effective_on]

    stub_payments([ 1_000, Date.new(2026, 11, 10) ], [ 1_100, Date.new(2027, 1, 20) ], [ 1_100, Date.new(2027, 2, 20) ])
    assert_empty generate
  end

  test "a change of exactly 3 percent is flagged and one just under is not" do
    stub_payments([ 1_000, Date.new(2026, 11, 10) ], [ 1_030, Date.new(2026, 12, 10) ], [ 1_030, Date.new(2027, 1, 10) ])
    assert_equal 1_030.0, generate.sole.metadata[:new_payment]

    stub_payments([ 1_000, Date.new(2026, 11, 10) ], [ 1_029.99, Date.new(2026, 12, 10) ], [ 1_029.99, Date.new(2027, 1, 10) ])
    assert_empty generate
  end

  test "a lower payment reads as good news at low priority" do
    stub_payments([ 1_616, Date.new(2026, 11, 10) ], [ 1_424, Date.new(2026, 12, 10) ], [ 1_424, Date.new(2027, 1, 10) ])

    insight = generate.sole

    assert_equal "loan_payment_change.down", insight.template_key
    assert_equal "low", insight.priority
  end

  test "a payment rise of 10 percent or more is high priority" do
    stub_payments([ 1_424, Date.new(2026, 11, 10) ], [ 1_616, Date.new(2026, 12, 10) ], [ 1_616, Date.new(2027, 1, 10) ])

    assert_equal "high", generate.sole.priority
  end

  test "the final payment absorbing rounding is not a change" do
    stub_payments([ 1_000, Date.new(2026, 11, 10) ], [ 400, Date.new(2026, 12, 10) ])

    assert_empty generate
  end

  test "a fixed loan with a level payment produces nothing" do
    @account.loan.update!(rate_type: "fixed", variable_rate_schedule: {})

    assert_empty generate
  end

  test "a loan without the terms to build a schedule produces nothing" do
    @account.loan.update!(term_months: nil)

    assert_empty generate
  end

  test "a family without loans produces nothing" do
    @account.destroy!

    assert_empty generate
  end

  test "skips a loan that is private to one member" do
    @share.destroy!

    assert_empty generate
  end

  test "writes the body in English and Spanish" do
    %i[en es].each do |locale|
      I18n.with_locale(locale) do
        insight = generate.sole
        body = Insight::BodyWriter.new.write(insight)

        assert_includes body, @account.name
        assert_includes body, { en: "16.5%", es: "16,5%" }.fetch(locale)
        assert_no_match(/translation missing/i, body)
        assert_no_match(/translation missing/i, insight.title)
      end
    end
  end

  private
    def generate
      Insight::Generators::LoanPaymentChangeGenerator.new(@family).generate
    end

    # A schedule reduced to what the generator reads: [amount, date] per payment.
    def stub_payments(*rows)
      payments = rows.each_with_index.map do |(amount, date), index|
        money = Money.new(amount, "USD")
        Loan::AmortizationSchedule::Payment.new(number: index + 1, date: date, payment: money,
                                                principal: money, interest: Money.new(0, "USD"),
                                                ending_balance: Money.new(0, "USD"))
      end
      Loan.any_instance.stubs(:amortization_schedule).returns(stub(payments: payments))
    end
end
