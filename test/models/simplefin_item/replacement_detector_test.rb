require "test_helper"

class SimplefinItem::ReplacementDetectorTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @item = SimplefinItem.create!(
      family: @family,
      name: "SF Conn",
      access_url: "https://example.com/access"
    )
  end

  def make_sfa(name:, account_id:, account_type: "credit", org_name: "Citibank",
               balance: -100, transactions: [])
    @item.simplefin_accounts.create!(
      name: name,
      account_id: account_id,
      currency: "USD",
      account_type: account_type,
      current_balance: balance,
      org_data: { "name" => org_name },
      raw_transactions_payload: transactions
    )
  end

  def link(sfa, name:)
    account = @family.accounts.create!(
      name: name,
      balance: (sfa.current_balance || 0).to_d,
      currency: sfa.currency,
      accountable: CreditCard.create!(subtype: "credit_card")
    )
    sfa.update!(account: account)
    account.update!(simplefin_account_id: sfa.id)
    account
  end

  def tx(when_ago:)
    { "id" => SecureRandom.hex(4), "transacted_at" => when_ago.ago.to_i, "posted" => when_ago.ago.to_i, "amount" => "-5" }
  end

  test "returns empty when simplefin_item has no accounts" do
    assert_equal [], SimplefinItem::ReplacementDetector.new(@item).call
  end

  test "returns empty when there are no active unlinked candidates" do
    dormant = make_sfa(name: "Citi Old", account_id: "sf_old", balance: 0, transactions: [ tx(when_ago: 90.days) ])
    link(dormant, name: "Citi Double Cash")
    # No unlinked sfas at all
    assert_equal [], SimplefinItem::ReplacementDetector.new(@item).call
  end

  test "detects classic fraud replacement: dormant+zero linked sfa + active unlinked sfa same org+type" do
    dormant = make_sfa(name: "Citi-3831", account_id: "sf_3831", balance: 0,
                       transactions: [ tx(when_ago: 45.days) ])
    linked_account = link(dormant, name: "Citi Double Cash Card-3831")
    active = make_sfa(name: "Citi-2879", account_id: "sf_2879", balance: -1200,
                      transactions: [ tx(when_ago: 2.days), tx(when_ago: 5.days) ])

    suggestions = SimplefinItem::ReplacementDetector.new(@item).call
    assert_equal 1, suggestions.size

    suggestion = suggestions.first
    assert_equal dormant.id, suggestion["dormant_sfa_id"]
    assert_equal active.id, suggestion["active_sfa_id"]
    assert_equal linked_account.id, suggestion["sure_account_id"]
    assert_equal "Citibank", suggestion["institution_name"]
    assert_equal "high", suggestion["confidence"]
  end

  test "ignores candidates at different institutions" do
    dormant = make_sfa(name: "Citi-3831", account_id: "sf_old", balance: 0,
                       transactions: [ tx(when_ago: 60.days) ])
    link(dormant, name: "Citi Double Cash")
    # Active sfa at a DIFFERENT institution - not a real replacement
    make_sfa(name: "Chase-Freedom", account_id: "sf_chase", balance: -200,
             org_name: "Chase",
             transactions: [ tx(when_ago: 3.days) ])

    assert_empty SimplefinItem::ReplacementDetector.new(@item).call
  end

  test "ignores candidates with different account_type" do
    dormant = make_sfa(name: "Citi-3831", account_id: "sf_old",
                       account_type: "credit", balance: 0,
                       transactions: [ tx(when_ago: 60.days) ])
    link(dormant, name: "Citi Double Cash")
    # Active sfa at same institution but different type
    make_sfa(name: "Citi Checking", account_id: "sf_checking",
             account_type: "depository", balance: 500,
             transactions: [ tx(when_ago: 3.days) ])

    assert_empty SimplefinItem::ReplacementDetector.new(@item).call
  end

  test "skips ambiguous matches (multiple candidates)" do
    dormant = make_sfa(name: "Citi-3831", account_id: "sf_old", balance: 0,
                       transactions: [ tx(when_ago: 60.days) ])
    link(dormant, name: "Citi Double Cash")
    # Two active unlinked Citi credit cards — can't tell which replaced it
    make_sfa(name: "Citi-2879", account_id: "sf_new1", balance: -100,
             transactions: [ tx(when_ago: 2.days) ])
    make_sfa(name: "Citi-4567", account_id: "sf_new2", balance: -200,
             transactions: [ tx(when_ago: 5.days) ])

    assert_empty SimplefinItem::ReplacementDetector.new(@item).call
  end

  test "ignores dormant sfa with non-zero balance (probably legitimate dormant account)" do
    # A savings account sitting at $5000 with no recent activity isn't
    # fraud replacement — it's just a savings account
    dormant = make_sfa(name: "Dormant Savings", account_id: "sf_savings",
                       balance: 5000, transactions: [ tx(when_ago: 60.days) ])
    link(dormant, name: "Savings Account")
    make_sfa(name: "Citi-2879", account_id: "sf_new", balance: -100,
             transactions: [ tx(when_ago: 2.days) ])

    assert_empty SimplefinItem::ReplacementDetector.new(@item).call
  end

  test "ignores active sfa as the 'dormant' candidate" do
    # Account with both dormant-looking AND active (recent activity): not dormant
    active_linked = make_sfa(name: "Citi-3831", account_id: "sf_still_active",
                             balance: 0, transactions: [ tx(when_ago: 3.days) ])
    link(active_linked, name: "Citi Card")
    make_sfa(name: "Citi-2879", account_id: "sf_candidate", balance: -100,
             transactions: [ tx(when_ago: 2.days) ])

    assert_empty SimplefinItem::ReplacementDetector.new(@item).call
  end

  test "suggestion uses case-insensitive org and type matching" do
    dormant = make_sfa(name: "Citi Old", account_id: "sf_old", balance: 0,
                       account_type: "CREDIT", org_name: "CITIBANK",
                       transactions: [ tx(when_ago: 60.days) ])
    link(dormant, name: "Citi Double Cash")
    active = make_sfa(name: "Citi New", account_id: "sf_new", balance: -100,
                      account_type: "credit", org_name: "Citibank",
                      transactions: [ tx(when_ago: 2.days) ])

    suggestions = SimplefinItem::ReplacementDetector.new(@item).call
    assert_equal 1, suggestions.size
    assert_equal active.id, suggestions.first["active_sfa_id"]
  end

  test "detects multiple independent replacements across institutions" do
    # Two fraud replacements in the same sync: Citi + Chase both replaced
    dormant_citi = make_sfa(name: "Citi-old", account_id: "sf_c_old", balance: 0,
                            transactions: [ tx(when_ago: 60.days) ])
    link(dormant_citi, name: "Citi")
    make_sfa(name: "Citi-new", account_id: "sf_c_new", balance: -100,
             transactions: [ tx(when_ago: 3.days) ])

    dormant_chase = make_sfa(name: "Chase-old", account_id: "sf_ch_old",
                             org_name: "Chase", balance: 0,
                             transactions: [ tx(when_ago: 60.days) ])
    link(dormant_chase, name: "Chase")
    make_sfa(name: "Chase-new", account_id: "sf_ch_new",
             org_name: "Chase", balance: -200,
             transactions: [ tx(when_ago: 1.day) ])

    suggestions = SimplefinItem::ReplacementDetector.new(@item).call
    assert_equal 2, suggestions.size
    orgs = suggestions.map { |s| s["institution_name"] }.sort
    assert_equal [ "Chase", "Citibank" ], orgs
  end

  test "ignores non-credit account types (checking, savings, investment)" do
    # Fraud-replacement UX is credit-card scoped for now. A depository/checking
    # pair that matches all other detector criteria must be skipped.
    dormant = make_sfa(name: "Old Checking", account_id: "sf_checking_old",
                       account_type: "depository", org_name: "Chase", balance: 0,
                       transactions: [ tx(when_ago: 60.days) ])
    link(dormant, name: "Old Checking")
    make_sfa(name: "New Checking", account_id: "sf_checking_new",
             account_type: "depository", org_name: "Chase", balance: 1234,
             transactions: [ tx(when_ago: 2.days) ])

    assert_empty SimplefinItem::ReplacementDetector.new(@item).call
  end

  test "ignores linked sfa with no transaction history (brand-new card, not dormant)" do
    # A newly linked card with zero balance and no transactions yet must NOT be
    # flagged as a replacement target. "Dormant" requires prior activity that
    # has since gone silent; an empty payload carries no such signal.
    fresh = make_sfa(name: "Brand New Citi", account_id: "sf_fresh", balance: 0, transactions: [])
    link(fresh, name: "Brand New Citi Card")
    make_sfa(name: "Other Citi", account_id: "sf_other", balance: -50,
             transactions: [ tx(when_ago: 2.days) ])

    assert_empty SimplefinItem::ReplacementDetector.new(@item).call
  end
end
