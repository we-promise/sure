require "test_helper"

class TradesControllerTest < ActionDispatch::IntegrationTest
  include ActionView::RecordIdentifier
  include EntryableResourceInterfaceTest

  setup do
    sign_in @user = users(:family_admin)
    @entry = entries(:trade)
  end

  # The header used to read the amount's sign and call every trade a buy or a
  # sell, so an inbound transfer — Questrade journals one, and so do the
  # self-custody wallets — was shown as a purchase it never was.
  test "the header calls a labelled trade what it is, not a buy or a sell" do
    @entry.trade.update!(investment_activity_label: "Transfer")

    get trade_url(@entry)

    assert_response :success
    # Scoped to the header's own line: "Buy" also appears in the quick-edit
    # picker further down the page.
    assert_select "span.text-secondary.text-sm", text: I18n.t("trades.header.transfer")
    assert_select "span.text-secondary.text-sm", text: I18n.t("trades.header.buy"), count: 0
  end

  test "the German header localizes supported provider activity labels" do
    @user.update!(locale: "de")

    translations = {
      "Buy" => "Kaufen",
      "Contribution" => "Einlage",
      "Dividend" => "Dividende",
      "Exchange" => "Umtausch",
      "Fee" => "Gebühr",
      "Interest" => "Zinsen",
      "Other" => "Sonstige",
      "Reinvestment" => "Reinvestition",
      "Sell" => "Verkaufen",
      "Sweep In" => "Sweep In",
      "Sweep Out" => "Sweep Out",
      "Transfer" => "Überweisung",
      "Withdrawal" => "Entnahme"
    }

    assert_equal Trade::ACTIVITY_LABELS.sort, translations.keys.sort

    translations.each do |activity_label, translation|
      key = activity_label.parameterize(separator: "_")

      assert_equal translation,
                   I18n.t("trades.header.#{key}", locale: :de, fallback: false, default: nil)

      @entry.trade.update!(investment_activity_label: activity_label)

      get trade_url(@entry)

      assert_response :success
      assert_select "span.text-secondary.text-sm", text: translation
    end
  end

  test "an unlabelled trade still reads from the amount" do
    @entry.trade.update!(investment_activity_label: nil)

    get trade_url(@entry)

    assert_response :success
    expected = @entry.amount.positive? ? I18n.t("trades.header.buy") : I18n.t("trades.header.sell")
    assert_select "span.text-secondary.text-sm", text: expected
  end

  # A label this view has no wording for must not blank the line out.
  test "an unknown label falls back rather than rendering nothing" do
    @entry.trade.update!(investment_activity_label: "Sweep In")
    I18n.backend.store_translations(:en, trades: { header: { sweep_in: nil } })

    get trade_url(@entry)

    assert_response :success
    expected = @entry.amount.positive? ? I18n.t("trades.header.buy") : I18n.t("trades.header.sell")
    assert_select "span.text-secondary.text-sm", text: expected
  ensure
    I18n.reload!
  end

  test "updates trade entry" do
    assert_no_difference [ "Entry.count", "Trade.count" ] do
      patch trade_url(@entry), params: {
        entry: {
          currency: "USD",
          entryable_attributes: {
            id: @entry.entryable_id,
            qty: 20,
            price: 20
          }
        }
      }
    end

    @entry.reload

    assert_enqueued_with job: SyncJob

    assert_equal 20, @entry.trade.qty
    assert_equal 20, @entry.trade.price
    assert_equal "USD", @entry.currency

    assert_redirected_to account_url(@entry.account)
  end

  test "creates deposit entry" do
    from_account = accounts(:depository) # Account the deposit is coming from

    assert_difference -> { Entry.count } => 2,
                      -> { Transaction.count } => 2,
                      -> { Transfer.count } => 1 do
      post trades_url(account_id: @entry.account_id), params: {
        model: {
          type: "deposit",
          date: Date.current,
          amount: 10,
          currency: "USD",
          transfer_account_id: from_account.id
        }
      }
    end

    assert_redirected_to @entry.account
  end

  test "creates withdrawal entry" do
    to_account = accounts(:depository) # Account the withdrawal is going to

    assert_difference -> { Entry.count } => 2,
                      -> { Transaction.count } => 2,
                      -> { Transfer.count } => 1 do
      post trades_url(account_id: @entry.account_id), params: {
        model: {
          type: "withdrawal",
          date: Date.current,
          amount: 10,
          currency: "USD",
          transfer_account_id: to_account.id
        }
      }
    end

    assert_redirected_to @entry.account
  end

  test "deposit and withdrawal has optional transfer account" do
    assert_difference -> { Entry.count } => 1,
                      -> { Transaction.count } => 1,
                      -> { Transfer.count } => 0 do
      post trades_url(account_id: @entry.account_id), params: {
        model: {
          type: "withdrawal",
          date: Date.current,
          amount: 10,
          currency: "USD"
        }
      }
    end

    created_entry = Entry.order(created_at: :desc).first

    assert created_entry.amount.positive?
    assert_redirected_to @entry.account
  end

  test "creates interest entry as trade with synthetic cash security when no ticker given" do
    assert_difference [ "Entry.count", "Trade.count" ], 1 do
      post trades_url(account_id: @entry.account_id), params: {
        model: {
          type: "interest",
          date: Date.current,
          amount: 10,
          currency: "USD"
        }
      }
    end

    created_entry = Entry.order(created_at: :desc).first

    assert created_entry.amount.negative?
    assert created_entry.trade?
    assert created_entry.trade.security.cash?
    assert_equal "Interest", created_entry.name
    assert_redirected_to @entry.account
  end

  test "creates interest entry as trade with security when ticker given" do
    assert_difference [ "Entry.count", "Trade.count" ], 1 do
      post trades_url(account_id: @entry.account_id), params: {
        model: {
          type: "interest",
          date: Date.current,
          amount: 10,
          currency: "USD",
          ticker: "AAPL|XNAS"
        }
      }
    end

    created_entry = Entry.order(created_at: :desc).first

    assert created_entry.amount.negative?
    assert created_entry.trade?
    assert_equal "AAPL", created_entry.trade.security.ticker
    assert_equal "Interest: AAPL", created_entry.name
    assert_redirected_to @entry.account
  end

  test "creates dividend entry as trade with required security" do
    assert_difference [ "Entry.count", "Trade.count" ], 1 do
      post trades_url(account_id: @entry.account_id), params: {
        model: {
          type: "dividend",
          date: Date.current,
          amount: 25,
          currency: "USD",
          ticker: "AAPL|XNAS"
        }
      }
    end

    created_entry = Entry.order(created_at: :desc).first

    assert created_entry.amount.negative?
    assert created_entry.trade?
    assert_equal 0, created_entry.trade.qty
    assert_equal "AAPL", created_entry.trade.security.ticker
    assert_equal "Dividend: AAPL", created_entry.name
    assert_equal "Dividend", created_entry.trade.investment_activity_label
    assert_redirected_to @entry.account
  end

  test "creating dividend without security returns error" do
    assert_no_difference [ "Entry.count", "Trade.count" ] do
      post trades_url(account_id: @entry.account_id), params: {
        model: {
          type: "dividend",
          date: Date.current,
          amount: 25,
          currency: "USD"
        }
      }
    end

    assert_response :unprocessable_entity
  end

  test "creates trade buy entry with fee" do
    assert_difference [ "Entry.count", "Trade.count" ], 1 do
      post trades_url(account_id: @entry.account_id), params: {
        model: {
          type: "buy",
          date: Date.current,
          ticker: "NVDA (NASDAQ)",
          qty: 10,
          price: 20,
          fee: 9.95,
          currency: "USD"
        }
      }
    end

    created_entry = Entry.order(created_at: :desc).first

    assert_in_delta 209.95, created_entry.amount.to_f, 0.001
    assert_in_delta 9.95, created_entry.trade.fee.to_f, 0.001
    assert_redirected_to account_url(created_entry.account)
  end

  test "creates trade sell entry with fee" do
    assert_difference [ "Entry.count", "Trade.count" ], 1 do
      post trades_url(account_id: @entry.account_id), params: {
        model: {
          type: "sell",
          date: Date.current,
          ticker: "AAPL (NYSE)",
          qty: 10,
          price: 20,
          fee: 9.95,
          currency: "USD"
        }
      }
    end

    created_entry = Entry.order(created_at: :desc).first

    # sell: signed_amount = -10 * 20 + 9.95 = -190.05
    assert_in_delta(-190.05, created_entry.amount.to_f, 0.001)
    assert_in_delta 9.95, created_entry.trade.fee.to_f, 0.001
    assert_redirected_to account_url(created_entry.account)
  end

  test "creates trade buy entry without fee defaults to zero" do
    post trades_url(account_id: @entry.account_id), params: {
      model: {
        type: "buy",
        date: Date.current,
        ticker: "NVDA (NASDAQ)",
        qty: 10,
        price: 20,
        currency: "USD"
      }
    }

    created_entry = Entry.order(created_at: :desc).first

    assert_in_delta 200, created_entry.amount.to_f, 0.001
    assert_equal 0, created_entry.trade.fee.to_f
  end

  test "update includes fee in amount" do
    patch trade_url(@entry), params: {
      entry: {
        currency: "USD",
        nature: "outflow",
        entryable_attributes: {
          id: @entry.entryable_id,
          qty: 10,
          price: 20,
          fee: 9.95
        }
      }
    }

    @entry.reload

    assert_in_delta 209.95, @entry.amount.to_f, 0.001
    assert_in_delta 9.95, @entry.trade.fee.to_f, 0.001
  end

  test "creates trade buy entry" do
    assert_difference [ "Entry.count", "Trade.count", "Security.count" ], 1 do
      post trades_url(account_id: @entry.account_id), params: {
        model: {
          type: "buy",
          date: Date.current,
          ticker: "NVDA (NASDAQ)",
          qty: 10,
          price: 10,
          currency: "USD"
        }
      }
    end

    created_entry = Entry.order(created_at: :desc).first

    assert created_entry.amount.positive?
    assert created_entry.trade.qty.positive?
    assert_equal "Entry created", flash[:notice]
    assert_enqueued_with job: SyncJob
    assert_redirected_to account_url(created_entry.account)
  end

  test "creates trade sell entry" do
    assert_difference [ "Entry.count", "Trade.count" ], 1 do
      post trades_url(account_id: @entry.account_id), params: {
        model: {
          type: "sell",
          ticker: "AAPL (NYSE)",
          date: Date.current,
          currency: "USD",
          qty: 10,
          price: 10
        }
      }
    end

    created_entry = Entry.order(created_at: :desc).first

    assert created_entry.amount.negative?
    assert created_entry.trade.qty.negative?
    assert_equal "Entry created", flash[:notice]
    assert_enqueued_with job: SyncJob
    assert_redirected_to account_url(created_entry.account)
  end

  test "unlock clears protection flags on user-modified entry" do
    # Mark as protected with locked_attributes on both entry and entryable
    @entry.update!(user_modified: true, locked_attributes: { "name" => Time.current.iso8601 })
    @entry.trade.update!(locked_attributes: { "qty" => Time.current.iso8601 })

    assert @entry.reload.protected_from_sync?

    post unlock_trade_path(@entry.trade)

    assert_redirected_to account_path(@entry.account)
    assert_equal "Entry unlocked. It may be updated on next sync.", flash[:notice]

    @entry.reload
    assert_not @entry.user_modified?
    assert_empty @entry.locked_attributes, "Entry locked_attributes should be cleared"
    assert_empty @entry.trade.locked_attributes, "Trade locked_attributes should be cleared"
    assert_not @entry.protected_from_sync?
  end

  test "unlock clears import_locked flag" do
    @entry.update!(import_locked: true)

    assert @entry.reload.protected_from_sync?

    post unlock_trade_path(@entry.trade)

    assert_redirected_to account_path(@entry.account)
    @entry.reload
    assert_not @entry.import_locked?
    assert_not @entry.protected_from_sync?
  end

  test "update locks saved attributes" do
    assert_not @entry.user_modified?
    assert_empty @entry.trade.locked_attributes

    patch trade_url(@entry), params: {
      entry: {
        currency: "USD",
        entryable_attributes: {
          id: @entry.entryable_id,
          qty: 50,
          price: 25
        }
      }
    }

    @entry.reload
    assert @entry.user_modified?
    assert @entry.trade.locked_attributes.key?("qty")
    assert @entry.trade.locked_attributes.key?("price")
  end

  test "turbo stream update includes lock icon for protected entry" do
    assert_not @entry.user_modified?

    patch trade_url(@entry), params: {
      entry: {
        currency: "USD",
        nature: "outflow",
        entryable_attributes: {
          id: @entry.entryable_id,
          qty: 50,
          price: 25
        }
      }
    }, as: :turbo_stream

    assert_response :success
    assert_match(/turbo-stream/, response.content_type)
    # The turbo stream should contain the lock icon link with protection tooltip
    assert_match(/title="Protected from sync"/, response.body)
    # And should contain the lock SVG (the path for lock icon)
    assert_match(/M7 11V7a5 5 0 0 1 10 0v4/, response.body)
  end

  test "quick edit badge update locks activity label" do
    assert_not @entry.user_modified?
    assert_empty @entry.trade.locked_attributes
    original_label = @entry.trade.investment_activity_label

    # Mimic the quick edit badge JSON request
    patch trade_url(@entry),
      params: {
        entry: {
          entryable_attributes: {
            id: @entry.entryable_id,
            investment_activity_label: original_label == "Buy" ? "Sell" : "Buy"
          }
        }
      }.to_json,
      headers: {
        "Content-Type" => "application/json",
        "Accept" => "text/vnd.turbo-stream.html"
      }

    assert_response :success
    assert_match(/turbo-stream/, response.content_type)
    # The turbo stream should contain the lock icon
    assert_match(/title="Protected from sync"/, response.body)

    @entry.reload
    assert @entry.user_modified?, "Entry should be marked as user_modified"
    assert @entry.trade.locked_attributes.key?("investment_activity_label"), "investment_activity_label should be locked"
    assert @entry.protected_from_sync?, "Entry should be protected from sync"
  end

  test "turbo stream update replaces the entry row with the compact partial when compact preview is enabled" do
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true, "transactions_compact" => true, "transactions_group_by_date" => true))

    patch trade_url(@entry), params: {
      entry: {
        currency: "USD",
        entryable_attributes: {
          id: @entry.entryable_id,
          qty: 50,
          price: 25
        }
      }
    }, as: :turbo_stream

    assert_response :success
    assert_match(/turbo-stream/, response.content_type)
    doc = Nokogiri::HTML::Document.parse(response.body)
    entry_row_stream = doc.css("turbo-stream[action='replace']").find { |s| s["target"] == dom_id(@entry) }
    assert entry_row_stream.present?, "Expected a turbo-stream replacing the entry row"
    # Compact partial renders a flex row; the full-size partial renders a grid-cols-12 row instead
    assert_no_match(/grid-cols-12/, entry_row_stream.to_html)
  end

  test "turbo stream update replaces the entry row with the full-size partial when compact preview is disabled" do
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => false, "transactions_compact" => true, "transactions_group_by_date" => true))

    patch trade_url(@entry), params: {
      entry: {
        currency: "USD",
        entryable_attributes: {
          id: @entry.entryable_id,
          qty: 50,
          price: 25
        }
      }
    }, as: :turbo_stream

    assert_response :success
    doc = Nokogiri::HTML::Document.parse(response.body)
    entry_row_stream = doc.css("turbo-stream[action='replace']").find { |s| s["target"] == dom_id(@entry) }
    assert entry_row_stream.present?, "Expected a turbo-stream replacing the entry row"
    assert_match(/grid-cols-12/, entry_row_stream.to_html)
  end

  test "turbo_stream update renders balance from explicit view_ctx/is_filtered params without referer" do
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true, "transactions_compact" => true, "transactions_group_by_date" => false))

    patch trade_url(@entry), params: {
      view_ctx: "account",
      is_filtered: "0",
      entry: {
        currency: "USD",
        entryable_attributes: {
          id: @entry.entryable_id,
          qty: 50,
          price: 25
        }
      }
    }, as: :turbo_stream

    assert_response :success
    assert_match(/justify-end px-2/, turbo_stream_row_html(@entry),
      "unfiltered account context should render the running balance")
  end

  test "turbo_stream update hides balance for explicit filtered or global context" do
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true, "transactions_compact" => true, "transactions_group_by_date" => false))

    patch trade_url(@entry), params: {
      view_ctx: "account",
      is_filtered: "1",
      entry: {
        currency: "USD",
        entryable_attributes: {
          id: @entry.entryable_id,
          qty: 50,
          price: 25
        }
      }
    }, as: :turbo_stream

    assert_response :success
    assert_no_match(/justify-end px-2/, turbo_stream_row_html(@entry))

    patch trade_url(@entry), params: {
      view_ctx: "global",
      is_filtered: "0",
      entry: {
        currency: "USD",
        entryable_attributes: {
          id: @entry.entryable_id,
          qty: 60,
          price: 25
        }
      }
    }, headers: { "Referer" => account_url(@entry.account) }, as: :turbo_stream

    assert_response :success
    assert_no_match(/justify-end px-2/, turbo_stream_row_html(@entry),
      "explicit global context must win over an account referer")
  end

  test "trade show drawer renders explicit view_ctx/is_filtered hidden fields" do
    get trade_url(@entry, view_ctx: "account", is_filtered: "1")

    assert_response :success
    assert_select "input[type='hidden'][name='view_ctx'][value='account']", minimum: 1
    assert_select "input[type='hidden'][name='is_filtered'][value='1']", minimum: 1
  end

  private
    # Extracts the entry-row turbo-stream's inner HTML from an update response,
    # so compact-row rendering (e.g. the running-balance column) can be asserted.
    def turbo_stream_row_html(entry)
      doc = Nokogiri::HTML::Document.parse(response.body)
      stream = doc.css("turbo-stream[action='replace']").find { |s| s["target"] == dom_id(entry) }
      assert stream.present?, "Expected a turbo-stream replacing the entry row"
      stream.to_html
    end
end
