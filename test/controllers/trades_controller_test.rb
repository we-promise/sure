require "test_helper"

class TradesControllerTest < ActionDispatch::IntegrationTest
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

  # A deposit or withdrawal books an entry on the other account too, so that
  # account needs write permission, not just the investment account.
  test "a withdrawal cannot book into an account the member may only read" do
    sign_in_as_member_with_writable_investment

    assert_no_difference [ "Entry.count", "Transfer.count" ] do
      post trades_url(account_id: @investment.id), params: {
        model: { type: "withdrawal", date: Date.current, amount: 10, currency: "USD", transfer_account_id: accounts(:credit_card).id }
      }
    end

    assert_equal I18n.t("accounts.not_authorized"), flash[:alert]
  end

  test "a deposit cannot draw from another member's private account" do
    sign_in_as_member_with_writable_investment

    assert_no_difference [ "Entry.count", "Transfer.count" ] do
      post trades_url(account_id: @investment.id), params: {
        model: { type: "deposit", date: Date.current, amount: 10, currency: "USD", transfer_account_id: accounts(:connected).id }
      }
    end

    assert_response :not_found
  end

  test "a member can still book a withdrawal into an account shared with full control" do
    sign_in_as_member_with_writable_investment

    assert_difference -> { Transfer.count } => 1 do
      post trades_url(account_id: @investment.id), params: {
        model: { type: "withdrawal", date: Date.current, amount: 10, currency: "USD", transfer_account_id: accounts(:depository).id }
      }
    end

    assert_redirected_to @investment
  end

  test "the transfer account picker only offers accounts the member may write to" do
    sign_in_as_member_with_writable_investment

    get new_trade_url(account_id: @investment.id, type: "withdrawal")

    assert_response :success
    assert_select "input[type=hidden][name='model[transfer_account_id]']"
    assert_select "[role=option][data-value='#{accounts(:depository).id}']"
    assert_select "[role=option][data-value='#{accounts(:credit_card).id}']", count: 0
    assert_select "[role=option][data-value='#{accounts(:connected).id}']", count: 0
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

  test "a linked deposit or withdrawal needs write access to the other account" do
    member = users(:family_member)
    sign_in member
    brokerage = member.family.accounts.create!(name: "Member Brokerage", owner: member, balance: 1_000,
                                               currency: "USD", accountable: Investment.new)
    read_only = member.family.accounts.create!(name: "Admin Read-only Checking", owner: @user, balance: 1_000,
                                               currency: "USD", accountable: Depository.new)
    read_only.account_shares.create!(user: member, permission: "read_only", include_in_finances: true)
    full_control = member.family.accounts.create!(name: "Admin Shared Checking", owner: @user, balance: 1_000,
                                                  currency: "USD", accountable: Depository.new)
    full_control.account_shares.create!(user: member, permission: "full_control", include_in_finances: true)
    unshared = member.family.accounts.create!(name: "Admin Private Checking", owner: @user, balance: 1_000,
                                              currency: "USD", accountable: Depository.new)

    get new_trade_url(account_id: brokerage.id, type: "deposit")
    assert_select "[role='option'][data-value=?]", full_control.id
    assert_select "[role='option'][data-value=?]", read_only.id, count: 0

    %w[deposit withdrawal].each do |type|
      assert_no_difference [ "Entry.count", "Transfer.count" ] do
        post trades_url(account_id: brokerage.id), params: {
          model: { type: type, date: Date.current, amount: 50, currency: "USD", transfer_account_id: read_only.id }
        }
      end
      assert_redirected_to account_path(read_only)
    end

    assert_no_difference [ "Entry.count", "Transfer.count" ] do
      post trades_url(account_id: brokerage.id), params: {
        model: { type: "withdrawal", date: Date.current, amount: 50, currency: "USD", transfer_account_id: unshared.id }
      }
    end
    assert_response :not_found

    assert_difference "Transfer.count", 1 do
      post trades_url(account_id: brokerage.id), params: {
        model: { type: "withdrawal", date: Date.current, amount: 50, currency: "USD", transfer_account_id: full_control.id }
      }
    end
    assert_redirected_to brokerage
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

  private
    # family_member gets the investment account with full control; fixtures
    # already share depository with full control and credit_card read-only,
    # and leave connected private to family_admin.
    def sign_in_as_member_with_writable_investment
      @investment = accounts(:investment)
      @investment.account_shares.create!(user: users(:family_member), permission: "full_control")
      sign_in users(:family_member)
    end
end
