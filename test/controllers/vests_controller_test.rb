require "test_helper"

class VestsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @account = accounts(:investment)
    @federal = @account.family.categories.create!(name: "Federal tax")
  end

  test "choosing a vest on the trade form opens the vest form" do
    get new_trade_url(account_id: @account.id, type: "vest")

    assert_redirected_to new_vest_url(account_id: @account.id)
  end

  test "the trade form offers a vest only on an investment account" do
    get new_trade_url(account_id: @account.id)
    assert_select "option[value=vest]"

    get new_trade_url(account_id: accounts(:crypto).id)
    assert_select "option[value=vest]", count: 0
  end

  test "the vest form takes the shares, the withheld shares, the income category, and the tax lines" do
    get new_vest_url(account_id: @account.id)

    assert_response :success
    %w[vested_qty units_withheld price income_category_id].each { |field| assert_select "[name='vest[#{field}]']" }
    assert_select "[name='vest[tax_lines][0][name]']"
    assert_select "[name='vest[tax_lines][0][category_id]']"
    assert_select "[name='vest[tax_lines][0][amount]']"
  end

  test "creates a vest with its income and taxes" do
    assert_difference -> { @account.entries.count }, 3 do
      post vests_url(account_id: @account.id), params: { vest: vest_params }
    end

    vest = @account.entries.joins("JOIN trades ON trades.id = entries.entryable_id")
                   .where(entryable_type: "Trade", trades: { investment_activity_label: Trade::VEST_LABEL }).last
    assert_equal 70, vest.trade.qty
    assert_equal [ -1000, 300 ], vest.vest_parts.map(&:amount).sort
    assert_redirected_to account_url(@account)
  end

  test "opening the vest, its income, or a tax opens the vest screen" do
    vest = create_vest

    get trade_url(vest)
    assert_redirected_to vest_url(vest)

    vest.vest_parts.each do |part|
      get transaction_url(part)
      assert_redirected_to vest_url(vest)
    end

    get vest_url(vest)
    assert_response :success
    assert_select "[name='vest[vested_qty]'][value='100.0']"
  end

  test "opening a vest's sale for taxes opens the vest screen" do
    form = Trade::VestForm.new(account: @account, manual_ticker: "AAPL", date: Date.current, vested_qty: 100, price: 10, sold_qty: 30)
    assert form.save, form.errors.full_messages.to_sentence
    sale = Trade::VestForm.parts_of(form.entry).last

    get trade_url(sale)
    assert_redirected_to vest_url(form.entry)
  end

  test "saving the vest screen updates the shares, the income, and the taxes together" do
    vest = create_vest
    part_ids = vest.vest_parts.pluck(:id).sort
    tax_id = Trade::VestForm.parts_of(vest).second.first.id

    patch vest_url(vest), params: { vest: vest_params(units_withheld: 40, tax_amount: 400, tax_id: tax_id) }

    vest.reload
    assert_equal 60, vest.trade.qty
    assert_equal [ -1000, 400 ], vest.vest_parts.map(&:amount).sort
    assert_equal part_ids, vest.vest_parts.pluck(:id).sort, "the same entries, updated in place"
  end

  test "deleting the vest deletes its income and taxes" do
    vest = create_vest

    assert_difference -> { @account.entries.count }, -3 do
      delete vest_url(vest)
    end
  end

  test "a vest whose income or tax is part of a transfer is not deleted" do
    vest = create_vest
    income = Trade::VestForm.parts_of(vest).first
    outflow = accounts(:depository).entries.create!(name: "Pay", date: Date.current, amount: 1000, currency: "USD", entryable: Transaction.new)
    # Transfers aren't matched to vest parts any more; this one stands for one
    # recorded before that rule.
    Transfer.new(inflow_transaction: income.transaction, outflow_transaction: outflow.transaction, status: "confirmed").save!(validate: false)

    assert_no_difference -> { @account.entries.count } do
      delete vest_url(vest)
    end
    assert_equal I18n.t("vests.destroy.part_transferred"), flash[:alert]
  end

  test "a trade that is not a vest has no vest screen" do
    get vest_url(entries(:trade))

    assert_response :not_found
  end

  private
    def vest_params(units_withheld: 30, tax_amount: 300, tax_id: nil)
      {
        manual_ticker: "AAPL", date: Date.current, vested_qty: 100, units_withheld: units_withheld, price: 10,
        tax_lines: { "0" => { id: tax_id, name: "Federal", category_id: @federal.id, amount: tax_amount } }
      }
    end

    def create_vest
      form = Trade::VestForm.new(account: @account, **vest_params.merge(tax_lines: vest_params[:tax_lines].values))
      assert form.save, form.errors.full_messages.to_sentence
      form.entry
    end
end
