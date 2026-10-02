require "test_helper"

class TransactionsTradeConversionTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  setup do
    @user = users(:family_admin)
    @account = accounts(:crypto)
    @account.crypto.update!(subtype: "exchange")
    @entry = create_transaction(account: @account, amount: 100)
    sign_in @user
  end

  test "trade-capable accounts return the conversion modal" do
    [ @account, accounts(:investment) ].each do |account|
      entry = create_transaction(account: account)

      get convert_to_trade_transaction_url(entry.transaction),
        params: { activity_label: "Buy" }, headers: { "Turbo-Frame" => "modal" }

      assert_response :success
      assert_select "turbo-frame#modal"
      assert_select "form[action=?]", create_trade_from_transaction_transaction_path(entry.transaction)
    end
  end

  test "conversion action follows the account's trade capability" do
    [ @account, accounts(:investment), accounts(:depository) ].each do |account|
      entry = create_transaction(account: account)

      get transaction_url(entry), headers: { "Turbo-Frame" => "drawer" }

      assert_response :success
      assert_select "form[action=?]", convert_to_trade_transaction_path(entry.transaction),
        count: account.supports_trades? ? 1 : 0
    end

    @account.crypto.update!(subtype: "wallet")
    get transaction_url(@entry), headers: { "Turbo-Frame" => "drawer" }
    assert_response :success
    assert_select "form[action=?]", convert_to_trade_transaction_path(@entry.transaction), count: 0
  end

  %w[Buy Sell].each do |label|
    test "converts a synced crypto exchange transaction to a #{label.downcase}" do
      @entry.update!(external_id: "provider-transaction", amount: label == "Buy" ? 100 : -100)

      assert_difference "Trade.count", 1 do
        post create_trade_from_transaction_transaction_url(@entry.transaction), params: {
          security_id: securities(:aapl).id, qty: 2, price: 50, investment_activity_label: label
        }
        assert_nil flash[:alert], flash[:alert]
      end

      assert_redirected_to account_path(@account)
      trade_entry = @account.entries.where(entryable_type: "Trade").order(:created_at).last
      assert_equal label, trade_entry.trade.investment_activity_label
      assert_equal label == "Buy" ? 2 : -2, trade_entry.trade.qty
      assert_equal label == "Buy" ? 100 : -100, trade_entry.amount
      assert_equal @entry.date, trade_entry.date
      assert_equal @entry.currency, trade_entry.currency
      assert trade_entry.user_modified?
      assert @entry.reload.excluded?
      assert_equal "provider-transaction", @entry.external_id
    end
  end

  test "wallets and bank accounts cannot open or submit the conversion" do
    @account.crypto.update!(subtype: "wallet")

    [ @account, accounts(:depository) ].each do |account|
      entry = create_transaction(account: account)
      get convert_to_trade_transaction_url(entry.transaction), headers: { "Turbo-Frame" => "modal" }
      assert_redirected_to transactions_path

      assert_no_difference "Trade.count" do
        post create_trade_from_transaction_transaction_url(entry.transaction), params: {
          security_id: securities(:aapl).id, qty: 2, price: 50, investment_activity_label: "Buy"
        }
      end
      assert_redirected_to transactions_path
      assert_not entry.reload.excluded?
    end
  end

  test "an excluded transaction cannot produce another trade" do
    @entry.update!(excluded: true)

    assert_no_difference "Trade.count" do
      post create_trade_from_transaction_transaction_url(@entry.transaction), params: {
        security_id: securities(:aapl).id, qty: 2, price: 50, investment_activity_label: "Buy"
      }
    end
    assert_redirected_to transactions_path
    assert @entry.reload.excluded?
  end

  test "invalid trade quantities leave the original transaction unchanged" do
    assert_no_difference "Trade.count" do
      post create_trade_from_transaction_transaction_url(@entry.transaction), params: {
        security_id: securities(:aapl).id, qty: 0, price: 50, investment_activity_label: "Buy"
      }
    end
    assert_redirected_to transactions_path
    assert_not @entry.reload.excluded?
  end

  test "a conversion completed during security lookup cannot be repeated" do
    [ @account, accounts(:investment) ].each do |account|
      entry = create_transaction(account: account)
      security = securities(:aapl)
      Security.expects(:find_by).with do |attributes|
        if attributes == { id: security.id }
          Entry.where(id: entry.id).update_all(excluded: true)
          true
        end
      end.returns(security)

      assert_no_difference "Trade.count" do
        post create_trade_from_transaction_transaction_url(entry.transaction), params: {
          security_id: security.id, qty: 2, price: 50, investment_activity_label: "Buy"
        }
      end
      assert_redirected_to transactions_path
      assert_equal I18n.t("transactions.convert_to_trade.errors.already_converted"), flash[:alert]
    end
  end

  test "inferred conversion values use an amount edited before the source lock" do
    [ @account, accounts(:investment) ].each do |account|
      [ { qty: 2 }, { price: 50 } ].each do |trade_params|
        entry = create_transaction(account: account, amount: 100)
        security = securities(:aapl)
        Security.expects(:find_by).with do |attributes|
          if attributes == { id: security.id }
            Entry.where(id: entry.id).update_all(amount: -200)
            true
          end
        end.returns(security)

        assert_difference "Trade.count", 1 do
          post create_trade_from_transaction_transaction_url(entry.transaction),
            params: trade_params.merge(security_id: security.id)
        end
        assert_nil flash[:alert]
        assert_redirected_to account_path(account)
        trade_entry = account.entries.where(entryable_type: "Trade").order(:created_at).last
        assert_equal(-200, trade_entry.amount)
        assert_equal "Sell", trade_entry.trade.investment_activity_label
        assert_equal trade_params[:qty] ? -2 : -4, trade_entry.trade.qty
        assert_equal trade_params[:qty] ? 100 : 50, trade_entry.trade.price
        assert entry.reload.excluded?
      end
    end
  end

  test "annotation-only and read-only shares cannot convert" do
    member = users(:family_member)
    share = @account.account_shares.create!(user: member, permission: "read_write")
    sign_in member

    %w[read_write read_only].each do |permission|
      share.update!(permission: permission)
      get convert_to_trade_transaction_url(@entry.transaction), headers: { "Turbo-Frame" => "modal" }
      assert_response :redirect

      assert_no_difference "Trade.count" do
        post create_trade_from_transaction_transaction_url(@entry.transaction), params: {
          security_id: securities(:aapl).id, qty: 2, price: 50, investment_activity_label: "Buy"
        }
      end
      assert_response :redirect
      assert_not @entry.reload.excluded?
    end
  end

  test "another family cannot convert the transaction" do
    sign_in users(:empty)

    get convert_to_trade_transaction_url(@entry.transaction), headers: { "Turbo-Frame" => "modal" }
    assert_response :not_found

    assert_no_difference "Trade.count" do
      post create_trade_from_transaction_transaction_url(@entry.transaction), params: {
        security_id: securities(:aapl).id, qty: 2, price: 50, investment_activity_label: "Buy"
      }
    end
    assert_not @entry.reload.excluded?
  end
end
