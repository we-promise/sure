require "test_helper"

class Account::Destruction::EffectsTest < ActiveSupport::TestCase
  include EntriesTestHelper, ActiveJob::TestHelper

  Effects = Account::Destruction::Effects

  test "existing transfer counterpart is affected without claiming its entry will be deleted" do
    root = accounts(:depository)
    result = Effects.capture(account: root)

    assert_equal root.family_id, result.family_id
    assert_equal root.id, result.root_account_id
    assert_equal root.entries.order(:id).pluck(:id), result.deleted_entry_ids
    assert_includes result.account_ids, accounts(:credit_card).id
    assert_includes result.affected_entry_ids, entries(:transfer_in).id
    refute_includes result.deleted_entry_ids, entries(:transfer_in).id
    assert_includes result.transaction_ids, transactions(:transfer_in).id
    assert_includes result.transfer_ids, transfers(:one).id
    assert_equal "account-destruction-effects/v1", result.proof.fetch("format")
    assert_deep_frozen result.proof
    %i[account_ids deleted_entry_ids affected_entry_ids transaction_ids transfer_ids goal_pledge_ids statement_ids].each do |field|
      ids = result.public_send(field)
      assert ids.frozen?
      assert_equal ids.uniq.sort, ids
    end
  end

  test "transfer fees and their split descendants are deleted while unrelated counterpart work stays outside the graph" do
    root, peer, unrelated = Array.new(3) { financial_account }
    transfer = transfer_between(root, peer)
    fee = transaction_entry(peer, amount: 6, transaction: Transaction.new(transfer_id: transfer.id))
    children = fee.split!([ { name: "Fee part one", amount: 2 }, { name: "Fee part two", amount: 4 } ])
    other = transfer_between(peer, unrelated)
    separate_entry = transaction_entry(peer)

    result = Effects.capture(account: root)

    assert_equal [ root.id, peer.id ].sort, result.account_ids
    assert_equal [ transfer.id ], result.transfer_ids
    assert_equal ([ transfer.outflow_transaction.entry.id, fee.id ] + children.map(&:id)).sort, result.deleted_entry_ids
    assert_includes result.affected_entry_ids, transfer.inflow_transaction.entry.id
    refute_includes result.deleted_entry_ids, transfer.inflow_transaction.entry.id
    refute_includes result.affected_entry_ids, separate_entry.id
    refute_includes result.affected_entry_ids, other.outflow_transaction.entry.id
    refute_includes result.account_ids, unrelated.id
  end

  test "root pledge cleanup and reverse matched pledges include the precise transaction owners" do
    root = accounts(:depository)
    peer = accounts(:connected)
    matched_peer = transaction_entry(peer, amount: -200)
    root_pledge = goal_pledges(:open_transfer)
    root_pledge.resolve_with!(matched_peer.transaction)
    deleted = transaction_entry(root, amount: -317)
    reverse = goals(:vacation_italy).goal_pledges.create!(account: peer, amount: 317, currency: "USD")
    reverse.resolve_with!(deleted.transaction)

    result = Effects.capture(account: root)

    assert_includes result.goal_pledge_ids, root_pledge.id
    assert_includes result.goal_pledge_ids, reverse.id
    assert_includes result.account_ids, peer.id
    assert_includes result.affected_entry_ids, matched_peer.id
    refute_includes result.deleted_entry_ids, matched_peer.id
    assert_includes result.deleted_entry_ids, deleted.id
    assert_equal root_pledge.id, matched_peer.transaction.reload.extra.dig("goal", "pledge_id")
    assert_equal reverse.id, deleted.transaction.reload.extra.dig("goal", "pledge_id")
  end

  test "rejected transfer counterparts are ownership witnesses rather than financial effects" do
    root, peer = Array.new(2) { financial_account }
    deleted = transaction_entry(root, amount: 20)
    witness = transaction_entry(peer, amount: -20)
    rejected = RejectedTransfer.create!(outflow_transaction: deleted.transaction, inflow_transaction: witness.transaction)

    result = Effects.capture(account: root)

    assert_equal [ root.id, peer.id ].sort, result.account_ids
    assert_equal [ deleted.id ], result.deleted_entry_ids
    assert_equal [ deleted.id ], result.affected_entry_ids
    assert_equal [ deleted.entryable_id, witness.entryable_id ].sort, result.transaction_ids
    assert_equal [ rejected.id ], result.proof.fetch("rejected_transfers").map { |row| row.fetch("id") }
    assert_empty result.transfer_ids
  end

  test "trade and valuation identities use their own delegated types in the scalar proof" do
    investment = Effects.capture(account: accounts(:investment))
    depository = Effects.capture(account: accounts(:depository))

    assert_includes investment.deleted_entry_ids, entries(:trade).id
    assert_includes investment.proof.fetch("trades").map { |row| row.fetch("id") }, entries(:trade).entryable_id
    assert_includes depository.deleted_entry_ids, entries(:valuation).id
    assert_includes depository.proof.fetch("valuations").map { |row| row.fetch("id") }, entries(:valuation).entryable_id
    refute_includes investment.transaction_ids, entries(:trade).entryable_id
    refute_includes depository.transaction_ids, entries(:valuation).entryable_id
  end

  test "linked and suggested statement headers are included without reading uploaded or parsed content" do
    root = financial_account
    linked = statement_header(account: root)
    suggested = statement_header(family: root.family, suggested_account: root)
    unrelated = statement_header(family: root.family)
    AccountStatement.any_instance.expects(:original_file).never
    AccountStatement.any_instance.expects(:sanitized_parser_output).never

    result = Effects.capture(account: root)

    assert_equal [ linked.id, suggested.id ].sort, result.statement_ids
    refute_includes result.statement_ids, unrelated.id
    assert_equal root.id, linked.reload.account_id
    assert_equal root.id, suggested.reload.suggested_account_id
  end

  test "capture performs only scalar reads and cannot expose financial or provider payload fields" do
    root = financial_account(name: "private-account-name")
    entry = transaction_entry(root, name: "private-entry-description", amount: BigDecimal("9876.5432"))
    entry.update!(notes: "private-entry-notes")
    entry.transaction.update!(extra: { "simplefin" => { "private" => "private-provider-payload" } })
    statement_header(account: root, filename: "private-statement-name.csv")
    before = [ root.reload.attributes, entry.reload.attributes, entry.transaction.reload.attributes ]
    result = nil

    queries = capture_sql_queries do
      assert_no_enqueued_jobs { result = Effects.capture(account: root) }
    end

    assert_empty queries.grep(/\A(?:INSERT|UPDATE|DELETE)\b/i)
    assert_empty queries.grep(/\bFOR\s+(?:UPDATE|SHARE|KEY SHARE|NO KEY UPDATE)\b/i)
    assert_equal before, [ root.reload.attributes, entry.reload.attributes, entry.transaction.reload.attributes ]
    %w[private-account-name private-entry-description private-entry-notes private-provider-payload private-statement-name.csv].each do |secret|
      refute_includes result.proof.to_json, secret
      refute_includes result.inspect, secret
    end
    forbidden = %w[name notes amount balance cash_balance extra sanitized_parser_output]
    result.proof.values.grep(Array).flatten.select { |value| value.is_a?(Hash) }.each do |header|
      assert_empty header.keys & forbidden
    end
  end

  test "cross-family transfer legs fees and split children refuse the entire graph" do
    %i[leg fee child].each do |edge|
      root, peer = Array.new(2) { financial_account }
      foreign = financial_account(family: families(:empty), name: "private-foreign-account")
      transfer = transfer_between(root, peer)
      foreign_entry = transaction_entry(foreign, name: "private-foreign-entry")
      case edge
      when :leg then transfer.update_columns(inflow_transaction_id: foreign_entry.entryable_id)
      when :fee then foreign_entry.transaction.update_columns(transfer_id: transfer.id)
      when :child then foreign_entry.update_columns(parent_entry_id: transfer.outflow_transaction.entry.id)
      end

      error = assert_raises(Effects::InvalidGraph) { Effects.capture(account: root) }
      refute_includes error.message, "private-foreign-account"
      refute_includes error.message, "private-foreign-entry"
      assert Entry.exists?(foreign_entry.id)
      assert Transfer.exists?(transfer.id)
    end
  end

  test "a foreign matched transaction or goal cannot be followed by a root pledge" do
    %i[transaction goal].each do |edge|
      root = accounts(:depository)
      pledge = goal_pledges(:open_transfer)
      if edge == :transaction
        foreign = financial_account(family: families(:empty))
        foreign_entry = transaction_entry(foreign)
        pledge.update_columns(matched_transaction_id: foreign_entry.entryable_id)
      else
        goals(:vacation_italy).update_columns(family_id: families(:empty).id)
      end

      assert_raises(Effects::InvalidGraph) { Effects.capture(account: root) }
      assert GoalPledge.exists?(pledge.id)
      pledge.update_columns(matched_transaction_id: nil)
      goals(:vacation_italy).update_columns(family_id: root.family_id)
    end
  end

  test "foreign statement ownership and forged caller tenancy are refused" do
    root = financial_account
    statement = statement_header(account: root)
    statement.update_columns(family_id: families(:empty).id)
    assert_raises(Effects::InvalidGraph) { Effects.capture(account: root) }
    statement.update_columns(family_id: root.family_id)
    stale = Account.find(root.id)
    stale.family_id = families(:empty).id
    assert_raises(Effects::InvalidGraph) { Effects.capture(account: stale) }
  end

  test "shared missing and unknown entryables cannot become incomplete deletion plans" do
    %i[shared missing unknown].each do |problem|
      root = financial_account
      entry = transaction_entry(root)
      case problem
      when :shared
        transaction_entry(financial_account).update_columns(entryable_id: entry.entryable_id)
      when :missing then entry.update_columns(entryable_id: SecureRandom.uuid)
      when :unknown then entry.update_columns(entryable_type: "PrivateUnknownType")
      end

      assert_raises(Effects::InvalidGraph) { Effects.capture(account: root) }
      assert Entry.exists?(entry.id)
    end
  end

  test "split cycles are rejected instead of producing an apparently complete graph" do
    root = financial_account
    first = transaction_entry(root)
    second = transaction_entry(root)
    first.update_columns(parent_entry_id: second.id)
    second.update_columns(parent_entry_id: first.id)

    assert_raises(Effects::InvalidGraph) { Effects.capture(account: root) }
    assert_equal second.id, first.reload.parent_entry_id
    assert_equal first.id, second.reload.parent_entry_id
  end

  test "a surviving split ancestor is an ownership witness without traversing its siblings" do
    root, peer = Array.new(2) { financial_account }
    parent = transaction_entry(peer)
    child = transaction_entry(root)
    sibling = transaction_entry(peer)
    child.update_columns(parent_entry_id: parent.id)
    sibling.update_columns(parent_entry_id: parent.id)

    result = Effects.capture(account: root)

    assert_equal [ root.id, peer.id ].sort, result.account_ids
    assert_equal [ child.id ], result.deleted_entry_ids
    assert_equal [ child.id ], result.affected_entry_ids
    assert_equal [ child.id, parent.id ].sort, result.proof.fetch("entries").map { |row| row.fetch("id") }
    refute_includes result.transaction_ids, sibling.entryable_id
    assert_equal parent.id, child.reload.parent_entry_id
    assert_equal parent.id, sibling.reload.parent_entry_id
  end

  test "a foreign split ancestor refuses the entire graph" do
    root = financial_account
    child = transaction_entry(root)
    foreign_parent = transaction_entry(financial_account(family: families(:empty)))
    child.update_columns(parent_entry_id: foreign_parent.id)

    assert_raises(Effects::InvalidGraph) { Effects.capture(account: root) }
    assert_equal foreign_parent.id, child.reload.parent_entry_id
  end

  test "a transfer leg that is also its own deletion fee is rejected as a cycle" do
    root, peer = Array.new(2) { financial_account }
    transfer = transfer_between(root, peer)
    transfer.outflow_transaction.update_columns(transfer_id: transfer.id)

    assert_raises(Effects::InvalidGraph) { Effects.capture(account: root) }
    assert_equal transfer.id, transfer.outflow_transaction.reload.transfer_id
    assert Transfer.exists?(transfer.id)
  end

  test "tuple versions detect payload changes within the same transaction" do
    root = financial_account
    entry = transaction_entry(root)
    before = Effects.capture(account: root)
    timestamp = entry.transaction.updated_at

    entry.transaction.update_columns(extra: { "private" => "same-transaction-private-value" })
    after = Effects.capture(account: root)

    assert_equal timestamp, entry.transaction.reload.updated_at
    assert_equal before.deleted_entry_ids, after.deleted_entry_ids
    refute_equal before.proof, after.proof
    refute_includes after.proof.to_json, "same-transaction-private-value"
  end

  test "row account and parent-depth bounds fail without returning partial inventories" do
    root, peer = Array.new(2) { financial_account }
    transfer_between(root, peer)
    with_limit(:MAX_ROWS, 2) { assert_raises(Effects::TooLarge) { Effects.capture(account: root) } }
    with_limit(:MAX_ACCOUNTS, 1) { assert_raises(Effects::TooLarge) { Effects.capture(account: root) } }
    chain_root = financial_account
    parent = transaction_entry(chain_root)
    4.times do
      child = transaction_entry(chain_root)
      child.update_columns(parent_entry_id: parent.id)
      parent = child
    end
    with_limit(:MAX_DEPTH, 2) { assert_raises(Effects::TooLarge) { Effects.capture(account: chain_root) } }
  end

  private

    def financial_account(family: families(:dylan_family), name: "Effects account")
      family.accounts.create!(name: name, currency: "USD", balance: 0, accountable: Depository.new)
    end

    def transaction_entry(account, amount: 10, name: "Effects transaction", transaction: Transaction.new)
      account.entries.create!(date: Date.current, amount: amount, name: name, currency: "USD", entryable: transaction)
    end

    def transfer_between(root, peer)
      outflow = transaction_entry(root, amount: 100, transaction: Transaction.new(kind: "funds_movement"))
      inflow = transaction_entry(peer, amount: -100, transaction: Transaction.new(kind: "funds_movement"))
      Transfer.create!(outflow_transaction: outflow.transaction, inflow_transaction: inflow.transaction, amount: 100, status: "confirmed")
    end

    def statement_header(account: nil, family: account&.family || families(:dylan_family), suggested_account: nil, filename: "statement.csv")
      # Inventory needs persisted headers only. Avoid uploading a blob or invoking
      # extraction/matching, which belong to separate statement tests.
      AccountStatement.new(family: family, account: account, suggested_account: suggested_account,
        filename: filename, byte_size: 10, content_type: "text/csv", checksum: SecureRandom.hex(16),
        sanitized_parser_output: { "private" => "private-statement-payload" }).tap { |statement| statement.save!(validate: false) }
    end

    def with_limit(name, value)
      previous = Effects.const_get(name)
      Effects.send(:remove_const, name)
      Effects.const_set(name, value)
      yield
    ensure
      Effects.send(:remove_const, name)
      Effects.const_set(name, previous)
    end

    def assert_deep_frozen(value)
      assert value.frozen?
      case value
      when Hash then value.each { |key, child| assert_deep_frozen(key); assert_deep_frozen(child) }
      when Array then value.each { |child| assert_deep_frozen(child) }
      end
    end
end

class Account::Destruction::EffectsCommitTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  test "committed payload edits change the scalar proof even when identities and timestamps do not change" do
    Family.any_instance.stubs(:broadcast_refresh)
    family = Family.create!(name: "Committed destruction proof")
    account = family.accounts.create!(name: "Proof account", currency: "USD", balance: 0, accountable: Depository.new)
    entry = account.entries.create!(date: Date.current, amount: 5, name: "Proof transaction", currency: "USD",
      entryable: Transaction.new(extra: { "private" => "first-private-value" }))
    before = Account::Destruction::Effects.capture(account: account)
    timestamp = entry.transaction.updated_at

    entry.transaction.update_columns(extra: { "private" => "second-private-value" })
    after = Account::Destruction::Effects.capture(account: account)

    assert_equal timestamp, entry.transaction.reload.updated_at
    assert_equal before.account_ids, after.account_ids
    assert_equal before.affected_entry_ids, after.affected_entry_ids
    assert_equal before.transaction_ids, after.transaction_ids
    refute_equal before.proof, after.proof
    refute_includes before.proof.to_json, "first-private-value"
    refute_includes after.proof.to_json, "second-private-value"
  ensure
    entry&.destroy!
    account&.destroy!
    family&.destroy!
  end
end
