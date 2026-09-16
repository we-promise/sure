require "set"

# A bounded, provisional inventory of financial deletion callbacks. This does
# not inventory every dependent-delete row or provider owner and cannot authorize
# deletion. Callers must admit every owner, lock the selected rows, and compare a
# fresh capture before making any writes. MAX_ROWS counts all distinct headers,
# including both an Entry and its entryable, rather than a count of transactions.
class Account::Destruction::Effects
  MAX_ROWS = 10_000
  MAX_ACCOUNTS = 100
  MAX_DEPTH = 32
  FORMAT = "account-destruction-effects/v1".freeze

  class InvalidGraph < StandardError; end
  class TooLarge < InvalidGraph; end

  Snapshot = Data.define(:family_id, :root_account_id, :account_ids, :deleted_entry_ids,
    :affected_entry_ids, :transaction_ids, :transfer_ids, :goal_pledge_ids, :statement_ids, :proof)

  # xmin/ctid detect update_columns/update_all changes even when updated_at is not
  # advanced, including within one transaction. Only scalar identity/version
  # headers leave the database; amounts, descriptions and JSON are not read.
  HEADERS = {
    "accounts" => [ Account, %w[id family_id owner_id accountable_type accountable_id currency status updated_at] ],
    "entries" => [ Entry, %w[id account_id entryable_type entryable_id parent_entry_id updated_at] ],
    "transactions" => [ Transaction, %w[id transfer_id kind updated_at] ],
    "trades" => [ Trade, %w[id security_id updated_at] ],
    "valuations" => [ Valuation, %w[id kind updated_at] ],
    "transfers" => [ Transfer, %w[id inflow_transaction_id outflow_transaction_id updated_at] ],
    "rejected_transfers" => [ RejectedTransfer, %w[id inflow_transaction_id outflow_transaction_id updated_at] ],
    "goal_pledges" => [ GoalPledge, %w[id account_id goal_id matched_transaction_id updated_at] ],
    "goals" => [ Goal, %w[id family_id updated_at] ],
    "statements" => [ AccountStatement, %w[id family_id account_id suggested_account_id updated_at] ]
  }.transform_values { |model, columns| [ model, columns.freeze ].freeze }.freeze
  ENTRYABLE_HEADERS = { "Transaction" => "transactions", "Trade" => "trades", "Valuation" => "valuations" }.freeze
  private_constant :HEADERS, :ENTRYABLE_HEADERS

  def self.capture(account:)
    new(account).capture
  end

  def initialize(account)
    unless account.is_a?(Account) && account.persisted? && account.id.present? && account.family_id.present?
      raise InvalidGraph, "Expected a persisted financial account"
    end
    @root_account_id, @family_id = account.id.dup, account.family_id.dup
    @rows = HEADERS.keys.to_h { |key| [ key, {} ] }
    @row_count = 0
    @deleted = Set.new
    @affected = Set.new
  end

  def capture
    ApplicationRecord.uncached do
      add_accounts!([ @root_account_id ])
      root_entries = read("entries", Entry.where(account_id: @root_account_id))
      add_entries!(root_entries, deleted: true, affected: true)
      root_pledges = read("goal_pledges", GoalPledge.where(account_id: @root_account_id))
      add_pledges!(root_pledges)
      add_transactions!(root_pledges.filter_map { |row| row["matched_transaction_id"] }, affected: true)

      expand_deletions!
      add_split_ancestors!
      verify_deletion_paths!
      add_statements!
      snapshot
    end
  end

  private
    def read(kind, scope)
      model, columns = HEADERS.fetch(kind)
      table = model.connection.quote_table_name(model.table_name)
      version = Arel.sql("#{table}.xmin::text")
      tuple = Arel.sql("#{table}.ctid::text")
      values = scope.reorder(:id).limit(MAX_ROWS + 1).pluck(*columns, version, tuple)
      raise TooLarge, "Financial deletion graph exceeds its row bound" if values.size > MAX_ROWS

      values.map do |values_row|
        (columns + [ "row_version", "tuple_version" ]).zip(values_row).to_h.transform_values do |value|
          value.respond_to?(:iso8601) ? value.iso8601(6) : value
        end
      end
    end

    def remember!(kind, rows)
      rows.each do |row|
        existing = @rows.fetch(kind)[row.fetch("id")]
        raise InvalidGraph, "Financial deletion graph changed during capture" if existing && existing != row
        next if existing

        @row_count += 1
        raise TooLarge, "Financial deletion graph exceeds its row bound" if @row_count > MAX_ROWS
        @rows.fetch(kind)[row.fetch("id")] = row
      end
    end

    def add_accounts!(ids)
      ids = ids.compact.uniq - @rows.fetch("accounts").keys
      return if ids.empty?
      if @rows.fetch("accounts").size + ids.size > MAX_ACCOUNTS
        raise TooLarge, "Financial deletion graph exceeds its account bound"
      end
      rows = read("accounts", Account.where(id: ids))
      unless rows.size == ids.size && rows.all? { |row| row["family_id"] == @family_id }
        raise InvalidGraph, "Financial deletion effect account is missing or belongs to another family"
      end
      remember!("accounts", rows)
    end

    def add_entries!(rows, deleted: false, affected: false)
      fresh = rows.reject { |row| @rows.fetch("entries").key?(row.fetch("id")) }
      fresh.group_by { |row| row["entryable_type"] }.each do |type, entries|
        kind = ENTRYABLE_HEADERS[type]
        ids = entries.map { |row| row["entryable_id"] }
        unless kind && ids.all?(&:present?) && ids.uniq.size == ids.size
          raise InvalidGraph, "Financial deletion entry has missing or ambiguous delegated ownership"
        end
        owners = read("entries", Entry.where(entryable_type: type, entryable_id: ids))
        unless owners.size == entries.size && owners.map { |row| row["id"] }.sort == entries.map { |row| row["id"] }.sort
          raise InvalidGraph, "Financial deletion entryable must have exactly one owner"
        end
        # Compare the original selection too: a reassignment between reads must
        # fail rather than silently switching to a freshly discovered owner.
        by_id = owners.index_by { |row| row.fetch("id") }
        unless entries.all? { |row| by_id[row.fetch("id")] == row }
          raise InvalidGraph, "Financial deletion entry ownership changed during capture"
        end
        model = HEADERS.fetch(kind).first
        entryables = read(kind, model.where(id: ids))
        raise InvalidGraph, "Financial deletion entryable is missing" unless entryables.size == ids.size
        remember!(kind, entryables)
      end
      add_accounts!(rows.map { |row| row["account_id"] })
      remember!("entries", rows)
      ids = rows.map { |row| row.fetch("id") }
      @deleted.merge(ids) if deleted
      @affected.merge(ids) if affected || deleted
    end

    def add_transactions!(ids, deleted: false, affected: false)
      ids = ids.compact.uniq
      return if ids.empty?
      owners = read("entries", Entry.where(entryable_type: "Transaction", entryable_id: ids))
      counts = owners.group_by { |row| row["entryable_id"] }
      unless counts.keys.sort == ids.sort && counts.values.all? { |rows| rows.one? }
        raise InvalidGraph, "Financial deletion transaction must have exactly one entry owner"
      end
      add_entries!(owners, deleted: deleted, affected: affected)
    end

    def expand_deletions!
      inspected = Set.new
      depth = 0
      loop do
        frontier = (@deleted - inspected).to_a.sort
        break if frontier.empty?
        raise TooLarge, "Financial deletion graph exceeds its traversal bound" if depth > MAX_DEPTH
        inspected.merge(frontier)
        children = read("entries", Entry.where(parent_entry_id: frontier))
        add_entries!(children, deleted: true)
        transaction_ids = frontier.filter_map do |id|
          row = @rows.fetch("entries").fetch(id)
          row["entryable_id"] if row["entryable_type"] == "Transaction"
        end
        expand_transactions!(transaction_ids) if transaction_ids.any?
        depth += 1
      end
    end

    def expand_transactions!(ids)
      scope = Transfer.where(inflow_transaction_id: ids).or(Transfer.where(outflow_transaction_id: ids))
      transfers = read("transfers", scope)
      fresh = transfers.reject { |row| @rows.fetch("transfers").key?(row.fetch("id")) }
      remember!("transfers", transfers)
      add_transactions!(fresh.flat_map { |row| [ row["inflow_transaction_id"], row["outflow_transaction_id"] ] }, affected: true)
      if fresh.any?
        # The raw FK identifies fee transactions; Transaction#transfer instead
        # resolves its inflow/outflow association and cannot identify this edge.
        fees = read("transactions", Transaction.where(transfer_id: fresh.map { |row| row["id"] }))
        remember!("transactions", fees)
        add_transactions!(fees.map { |row| row["id"] }, deleted: true)
      end

      rejected = read("rejected_transfers", RejectedTransfer.where(inflow_transaction_id: ids)
        .or(RejectedTransfer.where(outflow_transaction_id: ids)))
      remember!("rejected_transfers", rejected)
      # These counterparts are ownership witnesses, not financial row edits.
      add_transactions!(rejected.flat_map { |row| [ row["inflow_transaction_id"], row["outflow_transaction_id"] ] })
      add_pledges!(read("goal_pledges", GoalPledge.where(matched_transaction_id: ids)))
    end

    def add_pledges!(rows)
      add_accounts!(rows.map { |row| row["account_id"] })
      ids = rows.map { |row| row["goal_id"] }.uniq - @rows.fetch("goals").keys
      if ids.any?
        goals = read("goals", Goal.where(id: ids))
        unless goals.size == ids.size && goals.all? { |row| row["family_id"] == @family_id }
          raise InvalidGraph, "Financial deletion pledge goal is missing or belongs to another family"
        end
        remember!("goals", goals)
      end
      remember!("goal_pledges", rows)
    end

    def add_split_ancestors!
      depth = 0
      loop do
        ids = @rows.fetch("entries").values.filter_map { |row| row["parent_entry_id"] }.uniq - @rows.fetch("entries").keys
        break if ids.empty?
        raise TooLarge, "Financial deletion split graph exceeds its depth bound" if depth >= MAX_DEPTH
        ancestors = read("entries", Entry.where(id: ids))
        raise InvalidGraph, "Financial deletion split parent is missing" unless ancestors.size == ids.size
        # A surviving parent is an ownership witness. Deleting a child must not
        # turn its parent or siblings into additional deletion targets.
        add_entries!(ancestors)
        depth += 1
      end
    end

    def verify_deletion_paths!
      edges = @rows.fetch("entries").keys.to_h { |id| [ id, Set.new ] }
      transaction_entries = {}
      @rows.fetch("entries").each do |id, entry|
        parent = entry["parent_entry_id"]
        edges.fetch(parent).add(id) if edges.key?(parent)
        transaction_entries[entry["entryable_id"]] = id if @deleted.include?(id) && entry["entryable_type"] == "Transaction"
      end
      fees = @rows.fetch("transactions").values.group_by { |row| row["transfer_id"] }
      @rows.fetch("transfers").each_value do |transfer|
        [ transfer["inflow_transaction_id"], transfer["outflow_transaction_id"] ].each do |leg|
          parent = transaction_entries[leg]
          next unless parent
          Array(fees[transfer.fetch("id")]).each do |fee|
            child = transaction_entries[fee.fetch("id")]
            raise InvalidGraph, "Financial deletion fee entry is missing" unless child
            edges.fetch(parent).add(child)
          end
        end
      end
      heights = {}
      visiting = Set.new
      edges.each_key { |id| deletion_height!(id, edges, heights, visiting, 0) }
    end

    def deletion_height!(id, edges, heights, visiting, depth)
      raise TooLarge, "Financial deletion graph exceeds its depth bound" if depth > MAX_DEPTH
      if heights.key?(id)
        raise TooLarge, "Financial deletion graph exceeds its depth bound" if depth + heights.fetch(id) > MAX_DEPTH
        return heights.fetch(id)
      end
      raise InvalidGraph, "Financial deletion graph contains a cycle" unless visiting.add?(id)
      height = edges.fetch(id).map { |child| deletion_height!(child, edges, heights, visiting, depth + 1) + 1 }.max || 0
      visiting.delete(id)
      heights[id] = height
    end

    def add_statements!
      rows = read("statements", AccountStatement.where(account_id: @root_account_id)
        .or(AccountStatement.where(suggested_account_id: @root_account_id)))
      unless rows.all? { |row| row["family_id"] == @family_id }
        raise InvalidGraph, "Financial deletion statement belongs to another family"
      end
      add_accounts!(rows.flat_map { |row| [ row["account_id"], row["suggested_account_id"] ] })
      remember!("statements", rows)
    end

    def snapshot
      proof = { "format" => FORMAT, "family_id" => @family_id, "root_account_id" => @root_account_id }
      @rows.each { |kind, rows| proof[kind] = rows.values.sort_by { |row| row.fetch("id") } }
      values = {
        family_id: @family_id, root_account_id: @root_account_id,
        account_ids: @rows.fetch("accounts").keys.sort, deleted_entry_ids: @deleted.to_a.sort,
        affected_entry_ids: @affected.to_a.sort, transaction_ids: @rows.fetch("transactions").keys.sort,
        transfer_ids: @rows.fetch("transfers").keys.sort, goal_pledge_ids: @rows.fetch("goal_pledges").keys.sort,
        statement_ids: @rows.fetch("statements").keys.sort, proof: proof
      }
      Snapshot.new(**deep_freeze(values))
    end

    def deep_freeze(value)
      case value
      when Hash then value.each { |key, nested| deep_freeze(key); deep_freeze(nested) }
      when Array then value.each { |nested| deep_freeze(nested) }
      end
      value.freeze
    end
end
