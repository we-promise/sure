require "test_helper"

# Some ASPSPs first return a booked movement with neither transaction_id nor
# entry_reference, then replace it with an identified row whose remittance text
# was also rewritten (#4652). The content hash no longer matches, so only the
# replacement evidence of a complete fetch can tie the two together.
class EnableBankingItem::ImporterIdentifierReplacementTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @account = accounts(:depository)

    @enable_banking_item = EnableBankingItem.create!(
      family: @family,
      name: "Test EB",
      country_code: "FR",
      application_id: "test_app_id",
      client_certificate: "test_cert",
      session_id: "test_session",
      session_expires_at: 1.day.from_now,
      sync_start_date: 1.month.ago.to_date
    )
    @enable_banking_account = EnableBankingAccount.create!(
      enable_banking_item: @enable_banking_item,
      name: "Compte courant",
      uid: "hash_identifier_replacement_test",
      account_id: "uuid-replacement-1234",
      currency: "EUR"
    )
    AccountProvider.create!(account: @account, provider: @enable_banking_account)

    @provider = mock()
    @importer = EnableBankingItem::Importer.new(@enable_banking_item, enable_banking_provider: @provider)
    @importer.stubs(:include_pending?).returns(false)
    @importer.stubs(:determine_sync_start_date).returns(1.month.ago.to_date)
  end

  def booked_tx(text:, ref: nil, amount: "1000.00", date: 3.days.ago.to_date.to_s, direction: "CRDT")
    {
      transaction_id: nil,
      entry_reference: ref,
      booking_date: date,
      transaction_amount: { amount: amount, currency: "EUR" },
      credit_debit_indicator: direction,
      debtor: { name: "" },
      creditor: { name: "" },
      remittance_information: [ text ],
      status: "BOOK"
    }
  end

  def sync_and_process(booked)
    @importer.stubs(:fetch_paginated_transactions)
             .with(@enable_banking_account, has_entry(transaction_status: "BOOK")).returns(booked)
    @importer.send(:fetch_and_store_transactions, @enable_banking_account)
    EnableBankingAccount::Transactions::Processor.new(@enable_banking_account.reload).process
  end

  def entries = Entry.where(account_id: @account.id, source: "enable_banking")
  def external_id(tx) = EnableBankingEntry::Processor.compute_external_id(tx)

  test "an identified row with rewritten text replaces the identifierless row it superseded" do
    first = booked_tx(text: "VIR INST EXAMPLE CORP")
    sync_and_process([ first ])
    entry = entries.sole
    entry.transaction.update!(category: categories(:income))

    replacement = booked_tx(text: "VIR INST EXAMPLE CORP VIR DE EXAMPLE REF 123456", ref: "2026-10-28.1")
    sync_and_process([ replacement ])

    assert_equal 1, entries.count, "one bank operation must stay one entry"
    entry.reload
    assert_equal external_id(replacement), entry.external_id, "the existing entry is re-keyed, not replaced"
    assert_equal categories(:income), entry.transaction.category, "annotations survive the re-key"
    assert_includes Array(entry.transaction.extra[EnableBankingEntry::Processor::SUPERSEDED_IDS_KEY]),
                    external_id(first)
  end

  test "the retired identifierless row stays suppressed if the ASPSP returns it again" do
    first = booked_tx(text: "VIR INST EXAMPLE CORP")
    sync_and_process([ first ])
    replacement = booked_tx(text: "VIR INST EXAMPLE CORP REF 123456", ref: "2026-10-28.1")
    sync_and_process([ replacement ])

    sync_and_process([ first, replacement ])

    assert_equal 1, entries.count
  end

  test "an identified row replaced by its identifierless shape stays one entry under the bank identifier" do
    detailed = booked_tx(text: "CARTE\n0147572\nCB  TRIP.COM 17/10/26\nAMSTERDAM EUR 230,00", ref: "38bf5400",
                         amount: "230", direction: "DBIT")
    sync_and_process([ detailed ])
    entry = entries.sole
    entry.transaction.update!(category: categories(:food_and_drink))

    short = booked_tx(text: " CB  TRIP.COM         17/10/26 ", amount: "230", direction: "DBIT")
    sync_and_process([ short ])

    assert_equal 1, entries.count, "the short shape must not import beside the detailed one"
    entry.reload
    assert_equal external_id(detailed), entry.external_id, "the ASPSP identifier is kept"
    assert_equal categories(:food_and_drink), entry.transaction.category
    assert_includes Array(entry.transaction.extra[EnableBankingEntry::Processor::SUPERSEDED_IDS_KEY]),
                    external_id(short)
  end

  test "a movement whose shape alternates on every sync stays one entry" do
    detailed = booked_tx(text: "VIREMENT INSTANTANE\n\nVIR INST AXA EPARGNE\n\nIPR000367954585", ref: "58444ecd")
    short = booked_tx(text: "VIR INST AXA EPARGNE ENTREPRIS ")

    [ short, detailed, short, detailed, short ].each { |shape| sync_and_process([ shape ]) }

    assert_equal 1, entries.count
    assert_equal external_id(detailed), entries.sole.external_id
  end

  test "an identified row is never paired with another identified row on the loose key" do
    first = booked_tx(text: "VIR A", ref: "r1")
    sync_and_process([ first ])

    sync_and_process([ booked_tx(text: "VIR A REWRITTEN", ref: "r2") ])

    assert_equal 2, entries.count, "identified rotation is left to content pairing, never loosened"
  end

  test "an identifierless charge the ASPSP still returns is not claimed by a same-day identified charge" do
    card = booked_tx(text: "CARTE SHOP A", amount: "25.00", direction: "DBIT")
    sync_and_process([ card ])

    other = booked_tx(text: "CARTE SHOP B", amount: "25.00", direction: "DBIT", ref: "2026-10-28.7")
    sync_and_process([ card, other ])

    assert_equal 2, entries.count, "coexisting movements are separate movements"
    assert entries.exists?(external_id: external_id(card))
  end

  test "two genuine identified charges with the same date and amount stay apart" do
    first = booked_tx(text: "PEAGE A1", amount: "2.40", direction: "DBIT", ref: "2026-10-28.1")
    second = booked_tx(text: "PEAGE A1 GARE 2", amount: "2.40", direction: "DBIT", ref: "2026-10-28.2")
    sync_and_process([ first ])
    sync_and_process([ first, second ])
    sync_and_process([ first, second ])

    assert_equal 2, entries.count
  end

  test "equal numbers of replaced and replacing rows pair one to one" do
    olds = [ booked_tx(text: "VIR A"), booked_tx(text: "VIR B") ]
    sync_and_process(olds)

    news = [ booked_tx(text: "VIR A REF 1", ref: "r1"), booked_tx(text: "VIR B REF 2", ref: "r2") ]
    sync_and_process(news)

    assert_equal 2, entries.count
    assert_equal news.map { |tx| external_id(tx) }.sort, entries.pluck(:external_id).sort
  end

  test "an uneven replacement is ambiguous and left alone" do
    olds = [ booked_tx(text: "VIR A"), booked_tx(text: "VIR B") ]
    sync_and_process(olds)

    sync_and_process([ booked_tx(text: "VIR A REF 1", ref: "r1") ])

    assert_equal 3, entries.count, "no guess is made when the counts differ"
    olds.each { |tx| assert entries.exists?(external_id: external_id(tx)) }
  end

  test "a truncated booked fetch pairs nothing" do
    first = booked_tx(text: "VIR INST EXAMPLE CORP")
    sync_and_process([ first ])

    replacement = booked_tx(text: "VIR INST EXAMPLE CORP REF 123456", ref: "2026-10-28.1")
    @importer.unstub(:fetch_paginated_transactions)
    @provider.stubs(:get_account_transactions)
             .returns({ transactions: [ replacement ], continuation_key: "k1" })
             .then.returns({ transactions: [], continuation_key: "k1" })
    @importer.send(:fetch_and_store_transactions, @enable_banking_account)
    EnableBankingAccount::Transactions::Processor.new(@enable_banking_account.reload).process

    assert entries.exists?(external_id: external_id(first)), "pages never received are not evidence of removal"
  end

  test "a different booking date, amount or direction is not a replacement" do
    first = booked_tx(text: "VIR INST EXAMPLE CORP")
    sync_and_process([ first ])

    sync_and_process([
      booked_tx(text: "VIR INST EXAMPLE CORP REF 1", ref: "r1", date: 2.days.ago.to_date.to_s),
      booked_tx(text: "VIR INST EXAMPLE CORP REF 2", ref: "r2", amount: "1000.01"),
      booked_tx(text: "VIR INST EXAMPLE CORP REF 3", ref: "r3", direction: "DBIT")
    ])

    assert_equal 4, entries.count
    assert entries.exists?(external_id: external_id(first))
  end

  test "an identifier that already has an entry is not collided with" do
    first = booked_tx(text: "VIR INST EXAMPLE CORP")
    replacement = booked_tx(text: "VIR INST EXAMPLE CORP REF 123456", ref: "2026-10-28.1")

    # The state left behind by the bug: both copies already imported, and the
    # user excluded the identifierless one.
    sync_and_process([ first, replacement ])
    stale = entries.find_by!(external_id: external_id(first))
    stale.update!(excluded: true)

    sync_and_process([ replacement ])

    assert_equal 2, entries.count
    assert stale.reload.excluded?
    assert_equal external_id(first), stale.external_id
  end
end
