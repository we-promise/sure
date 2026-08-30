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

  test "offers category, tags and notes when the survivor has none" do
    setup_pair!
    tag = @family.tags.create!(name: "Reimbursable")
    category = @family.categories.create!(name: "Groceries")
    orphan_transaction.update!(category: category, tag_ids: [ tag.id ])
    orphan_entry.update!(notes: "split with a friend")

    candidate = @eba.card_twin_candidates.to_a.sole

    assert_equal category, candidate.category
    assert_equal [ tag.id ], candidate.tag_ids
    assert_equal "split with a friend", candidate.notes
    assert candidate.transfers_anything?
  end

  test "offers nothing for a field the survivor already has" do
    setup_pair!
    kept = @family.categories.create!(name: "Groceries")
    other = @family.categories.create!(name: "Shopping")
    survivor_transaction.update!(category: kept)
    orphan_transaction.update!(category: other)

    assert_nil @eba.card_twin_candidates.to_a.sole.category
  end

  test "offers nothing when the survivor is protected from sync" do
    setup_pair!
    category = @family.categories.create!(name: "Groceries")
    orphan_transaction.update!(category: category)
    survivor_entry.update!(user_modified: true)

    candidate = @eba.card_twin_candidates.to_a.sole

    assert_nil candidate.category
    assert_empty candidate.tag_ids
    refute candidate.transfers_anything?
  end

  test "flags a transfer as a blocker" do
    setup_pair!
    Transfer.create!(
      inflow_transaction: counterpart_inflow.entryable,
      outflow_transaction: orphan_transaction,
      amount: orphan_entry.amount.abs
    )

    candidate = @eba.card_twin_candidates.to_a.sole

    assert_includes candidate.blockers, :transfer
    assert candidate.blocked?
  end

  test "flags an attachment as a blocker" do
    setup_pair!
    orphan_transaction.attachments.attach(
      io: StringIO.new("receipt"), filename: "receipt.png", content_type: "image/png"
    )

    assert_includes @eba.card_twin_candidates.to_a.sole.blockers, :attachment
  end

  test "an untouched candidate is not blocked" do
    setup_pair!

    candidate = @eba.card_twin_candidates.to_a.sole

    assert_empty candidate.blockers
    refute candidate.blocked?
    refute candidate.transfers_anything?
  end

  test "copies category, tags and notes to the survivor then destroys the duplicate" do
    setup_pair!
    tag = @family.tags.create!(name: "Reimbursable")
    category = @family.categories.create!(name: "Groceries")
    orphan_transaction.update!(category: category, tag_ids: [ tag.id ])
    orphan_entry.update!(notes: "split with a friend")
    orphan_id = orphan_entry.id

    assert_difference "Entry.count", -1 do
      @eba.card_twin_candidates.to_a.sole.remove!
    end

    assert_nil Entry.find_by(id: orphan_id)
    survivor_entry.reload
    assert_equal category, survivor_transaction.category
    assert_equal [ tag.id ], survivor_transaction.tag_ids
    assert_equal "split with a friend", survivor_entry.notes
    assert survivor_entry.user_modified?
  end

  test "does not mark the survivor user_modified when nothing was copied" do
    setup_pair!

    @eba.card_twin_candidates.to_a.sole.remove!

    refute survivor_entry.reload.user_modified?
  end

  test "leaves a protected survivor untouched" do
    setup_pair!
    category = @family.categories.create!(name: "Groceries")
    orphan_transaction.update!(category: category)
    survivor_entry.update!(user_modified: true)

    assert_difference "Entry.count", -1 do
      @eba.card_twin_candidates.to_a.sole.remove!
    end

    assert_nil survivor_transaction.reload.category_id
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
    # One twin pair, post-fix: enable_banking_mcrd_1 is the orphan,
    # enable_banking_ccrd_1 is the survivor.
    def setup_pair!
      customer = row(code: "CCRD", sub_code: "POSD", ref: "ccrd_1", creditor: "ACME Mktp*K4T9QX2")
      merchant = row(code: "MCRD", sub_code: "UPCT", ref: "mcrd_1", creditor: "ACME Mktp")
      import!([ customer, merchant ])
      apply_fix!([ customer ])
    end

    def orphan_entry = @account.entries.find_by!(external_id: "enable_banking_mcrd_1")
    def survivor_entry = @account.entries.find_by!(external_id: "enable_banking_ccrd_1")
    def orphan_transaction = orphan_entry.entryable
    def survivor_transaction = survivor_entry.entryable

    # A Transfer is only valid across two accounts of the same family, so the
    # matching inflow lives on the family's other account.
    def counterpart_inflow
      accounts(:credit_card).entries.create!(
        name: "Inflow", date: orphan_entry.date, amount: -orphan_entry.amount,
        currency: orphan_entry.currency, entryable: Transaction.new
      )
    end

    def apply_fix!(surviving_rows)
      @eba.update!(raw_transactions_payload: surviving_rows)
      @eba.reload
    end
end
