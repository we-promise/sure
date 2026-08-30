require "test_helper"

class EnableBankingAccount::CardTwinCandidatesTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @item = EnableBankingItem.create!(
      family: @family, name: "Test Bank", country_code: "DE", application_id: "app",
      client_certificate: "cert", session_id: "sess", session_expires_at: 1.day.from_now
    )
    @account = accounts(:depository)
    @eba = EnableBankingAccount.create!(
      enable_banking_item: @item, name: "Test Account",
      uid: "hash_twin_candidates", account_id: "uuid-twin-candidates", currency: "EUR"
    )
    AccountProvider.create!(account: @account, provider: @eba)
  end

  test "finds the merchant-side entry the snapshot filter left behind" do
    customer = row(code: "CCRD", sub_code: "POSD", ref: "ccrd_1", creditor: "ACME Mktp*K4T9QX2")
    merchant = row(code: "MCRD", sub_code: "UPCT", ref: "mcrd_1", creditor: "ACME Mktp")

    import!([ customer, merchant ])
    apply_fix!([ customer ])

    candidates = @eba.card_twin_candidates.to_a

    assert_equal 1, candidates.size
    assert_equal "enable_banking_mcrd_1", candidates.first.entry.external_id
    assert_equal "enable_banking_ccrd_1", candidates.first.survivor.external_id
  end

  test "keeps both cardholder rows when two identical purchases were double-booked" do
    customer_1 = row(code: "CCRD", sub_code: "POSD", ref: "ccrd_1", creditor: "ACME Mktp*K4T9QX2")
    merchant_1 = row(code: "MCRD", sub_code: "UPCT", ref: "mcrd_1", creditor: "ACME Mktp")
    customer_2 = row(code: "CCRD", sub_code: "POSD", ref: "ccrd_2", creditor: "ACME Mktp*P8W1ZR5")
    merchant_2 = row(code: "MCRD", sub_code: "UPCT", ref: "mcrd_2", creditor: "ACME Mktp")

    import!([ customer_1, merchant_1, customer_2, merchant_2 ])
    apply_fix!([ customer_1, customer_2 ])

    removable = @eba.card_twin_candidates.map { |c| c.entry.external_id }.sort

    assert_equal [ "enable_banking_mcrd_1", "enable_banking_mcrd_2" ], removable
  end

  test "handles rows carrying neither transaction_id nor entry_reference" do
    customer = row(code: "CCRD", sub_code: "POSD", ref: nil, creditor: "ACME Mktp*K4T9QX2")
    merchant = row(code: "MCRD", sub_code: "UPCT", ref: nil, creditor: "ACME Mktp")
    merchant_id = EnableBankingEntry::Processor.compute_external_id(merchant)

    import!([ customer, merchant ])
    apply_fix!([ customer ])

    assert_equal [ merchant_id ], @eba.card_twin_candidates.map { |c| c.entry.external_id }
  end

  # Predicate 2. Turning off Setting.syncs_include_pending makes importer.rb:495
  # reject every stored pending row without checking whether it settled, and
  # nothing deletes the entries those rows created.
  test "ignores a pending entry orphaned by turning the pending setting off" do
    booked = row(code: "CCRD", sub_code: "POSD", ref: "book_1", creditor: "Corner Store")
    pending = row(code: "CCRD", sub_code: "POSD", ref: "pdng_1", creditor: "Corner Store",
                  amount: "9.99", pending: true)

    import!([ booked, pending ])
    apply_fix!([ booked ])

    assert_empty @eba.card_twin_candidates.to_a
  end

  # Predicate 2. A settlement at a different amount (tip, FX, fuel hold) is
  # matched by entry_reference at importer.rb:522 so the stored pending row is
  # stripped, but the auto-claim at provider_import_adapter.rb:118 needs an exact
  # amount, so the stale pending entry survives, orphaned.
  test "ignores a pending entry orphaned by a settlement at a different amount" do
    pending = row(code: "CCRD", sub_code: "POSD", ref: "ref_x", creditor: "Corner Store",
                  amount: "5.12", pending: true)
    settled = row(code: "CCRD", sub_code: "POSD", ref: "ref_x", creditor: "Corner Store",
                  amount: "5.47").merge("transaction_id" => "txn_settled")

    import!([ pending ])
    import!([ pending, settled ])
    apply_fix!([ settled ])

    assert_empty @eba.card_twin_candidates.to_a
  end

  # Predicate 3. Deleting and re-adding a connection creates a new
  # EnableBankingAccount whose snapshot starts empty, which would otherwise make
  # every older booked entry look orphaned.
  test "ignores an orphan with no surviving sibling" do
    lonely = row(code: "CCRD", sub_code: "POSD", ref: "lonely_1", creditor: "Bakery")
    other = row(code: "CCRD", sub_code: "POSD", ref: "other_1", creditor: "Corner Store",
                amount: "31.00")

    import!([ lonely, other ])
    apply_fix!([ other ])

    assert_empty @eba.card_twin_candidates.to_a
  end

  test "never lists a split child" do
    customer = row(code: "CCRD", sub_code: "POSD", ref: "ccrd_1", creditor: "ACME Mktp*K4T9QX2")
    merchant = row(code: "MCRD", sub_code: "UPCT", ref: "mcrd_1", creditor: "ACME Mktp")

    import!([ customer, merchant ])
    apply_fix!([ customer ])

    orphan = @account.entries.find_by(external_id: "enable_banking_mcrd_1")
    parent = @account.entries.create!(
      name: "Parent", date: orphan.date, amount: orphan.amount, currency: orphan.currency,
      entryable: Transaction.new
    )
    orphan.update!(parent_entry_id: parent.id)

    assert_empty @eba.card_twin_candidates.to_a
  end

  private
    def row(code:, sub_code:, ref:, creditor:, amount: "5.12", pending: false)
      base = {
        "entry_reference" => ref,
        "transaction_id" => nil,
        "booking_date" => "2026-02-11",
        "value_date" => "2026-02-11",
        "transaction_amount" => { "amount" => amount, "currency" => "EUR" },
        "credit_debit_indicator" => "DBIT",
        "status" => "BOOK",
        "creditor" => { "name" => creditor },
        "bank_transaction_code" => { "code" => code, "sub_code" => sub_code, "description" => "PMNT" }
      }
      pending ? base.merge("_pending" => true) : base
    end

    # Pre-fix state: the snapshot holds every row and the entries exist.
    def import!(rows)
      @eba.update!(raw_transactions_payload: rows)
      EnableBankingAccount::Transactions::Processor.new(@eba).process
      @eba.reload
    end

    # What #3274's snapshot filter leaves behind: the merchant-side rows are gone
    # from raw_transactions_payload, their entries are not.
    def apply_fix!(surviving_rows)
      @eba.update!(raw_transactions_payload: surviving_rows)
      @eba.reload
    end
end
