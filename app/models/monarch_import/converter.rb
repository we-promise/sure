# Converts Monarch's exports into the records Family::DataImporter imports,
# following the person's choice for each account.
#
# A new account gets the Monarch history as an opening balance plus balance
# valuations wherever its transactions don't explain Monarch's balance. An
# existing Sure account gets the same, computed on top of the entries it
# already has, and its opening balance moves to the start of the Monarch
# history when it falls inside it.
#
# Existing categories and merchants with the same names are reused with their
# current look: the records carry it, because DataImporter rewrites both from
# the record.
class MonarchImport::Converter
  TRANSFER_CATEGORY_KINDS = {
    "Transfer" => "funds_movement",
    "Credit Card Payment" => "cc_payment"
  }.freeze
  RECORD_ORDER = %w[Account Category Tag Merchant Transaction Valuation].freeze
  LIABILITY_TYPES = %w[CreditCard Loan OtherLiability].freeze

  # What the person picked for one Monarch account. name is Monarch's, and
  # account_name what a new Sure account is called. target is an existing
  # manual Account to import into, or nil to create one. current_balance is
  # today's balance as Sure shows it, with amounts owed positive.
  Choice = Data.define(:name, :type, :closed, :include, :transactions, :current_balance, :target, :account_name) do
    def initialize(account_name: nil, **attributes)
      super(account_name: account_name || attributes[:name], **attributes)
    end

    def liability?
      LIABILITY_TYPES.include?(type)
    end
  end

  # An existing account's opening balance, moved to the start of the history.
  OpeningBalanceMove = Data.define(:account, :entry, :date, :balance)

  Result = Data.define(:records, :stats, :opening_balance_moves, :conflicts, :overlapping_transactions)

  def self.source_id(name)
    "monarch-account:#{name}"
  end

  def initialize(exports:, choices:, family:, include_pending: false, today: nil)
    @exports = exports
    @choices = choices.index_by(&:name)
    @family = family
    @include_pending = include_pending
    @today = today || default_today
  end

  def result
    @result ||= convert
  end

  private
    attr_reader :exports, :family, :today

    def convert
      unknown = exports.account_names - @choices.keys
      raise ArgumentError, "No choice for #{unknown.join(', ')}" if unknown.any?

      @records = RECORD_ORDER.index_with { [] }
      @stats = Hash.new(0)
      @categories = {}
      @tags = {}
      @merchants = {}
      @opening_balance_moves = []
      @conflicts = {}
      @overlapping_transactions = {}

      flows = convert_transactions
      exports.account_names.each { |name| convert_account(@choices[name], flows.fetch(name, {})) }
      convert_categories_tags_and_merchants

      RECORD_ORDER.each { |type| @stats[type] = @records[type].size }
      Result.new(
        records: RECORD_ORDER.flat_map { |type| @records[type] },
        stats: @stats.to_h,
        opening_balance_moves: @opening_balance_moves,
        conflicts: @conflicts,
        overlapping_transactions: @overlapping_transactions
      )
    end

    # Adds the transaction records and returns each account's daily flows.
    def convert_transactions
      flows = Hash.new { |hash, name| hash[name] = Hash.new(BigDecimal("0")) }

      exports.transactions_for(include_pending: @include_pending).each do |row|
        choice = @choices[row[:account]]
        skipped = if !choice.include then "excluded_account"
        elsif !choice.transactions then "balances_only"
        elsif row[:amount].nil? then "no_amount"
        end
        next @stats["transactions_skipped_#{skipped}"] += 1 if skipped

        flows[row[:account]][row[:date]] += row[:amount]

        kind = TRANSFER_CATEGORY_KINDS.fetch(row[:category], "standard")
        data = {
          "id" => "monarch-transaction:#{row[:id]}",
          "account_id" => self.class.source_id(row[:account]),
          "date" => row[:date].iso8601,
          # Sure records outflows as positive amounts; Monarch as negative.
          "amount" => money(-row[:amount]),
          "name" => row[:merchant].presence || row[:original_statement].presence || "Imported transaction",
          "notes" => row[:notes].presence,
          "kind" => kind
        }
        if row[:category].present? && kind == "standard"
          data["category_id"] = @categories[row[:category]] ||= "monarch-category:#{row[:category]}"
        end
        if row[:merchant].present?
          data["merchant_id"] = @merchants[row[:merchant]] ||= "monarch-merchant:#{row[:merchant]}"
        end
        tag_ids = row[:tags].map { |tag| @tags[tag] ||= "monarch-tag:#{tag}" }
        data["tag_ids"] = tag_ids if tag_ids.any?

        @records["Transaction"] << record("Transaction", data)
      end

      flows
    end

    def convert_account(choice, flows)
      return unless choice.include

      sign = choice.liability? ? -1 : 1 # Sure stores amounts owed as positive
      history = exports.balances.fetch(choice.name, {})
      current_balance = choice.current_balance && choice.current_balance * sign

      if choice.target
        convert_into_existing(choice, history, flows, sign, current_balance)
      else
        balance_history = MonarchImport::BalanceHistory.new(history: history, flows: flows, closed: choice.closed)
        anchors = anchors_for(balance_history, choice, current_balance)
        @records["Account"] << record("Account", {
          "id" => self.class.source_id(choice.name),
          "name" => choice.account_name,
          "accountable_type" => choice.type,
          "accountable" => {},
          "subtype" => nil,
          "balance" => money((balance_history.replay(anchors).values.last || 0) * sign),
          "status" => choice.closed ? "disabled" : "active",
          # The opening balance and history come from the valuations.
          "skip_opening_balance_import" => true
        })
        add_valuations(choice, anchors, sign, first_kind: "opening_anchor")
      end
    end

    def convert_into_existing(choice, history, flows, sign, current_balance)
      account = choice.target
      entries = account.entries.excluding_pending.includes(:entryable).to_a
      valuations, others = entries.partition { |entry| entry.entryable_type == "Valuation" }
      opening = valuations.find { |entry| entry.entryable.opening_anchor? }
      existing_valuations = valuations.to_h { |entry| [ entry.date, entry.amount * sign ] }
      existing_flows = others.each_with_object(Hash.new(BigDecimal("0"))) { |entry, sums| sums[entry.date] -= entry.amount }

      monarch_dates = history.keys + flows.keys
      start_date, end_date = monarch_dates.minmax
      @overlapping_transactions[choice.name] = others.count { |entry| entry.date.between?(start_date, end_date) } if start_date

      # The opening balance can move to the start of the history when it falls
      # inside it and nothing else in the account comes earlier.
      if opening && start_date && opening.date >= start_date
        movable_valuations = existing_valuations.except(opening.date)
        balance_history = MonarchImport::BalanceHistory.new(history: history, flows: flows, closed: choice.closed,
          existing_valuations: movable_valuations, existing_flows: existing_flows)
        anchors = anchors_for(balance_history, choice, current_balance)
        opening_date, opening_balance = anchors.first
        if opening_date && (entries - [ opening ]).none? { |entry| entry.date <= opening_date }
          @opening_balance_moves << OpeningBalanceMove.new(account: account, entry: opening, date: opening_date, balance: opening_balance * sign)
          @conflicts[choice.name] = balance_history.conflicts if balance_history.conflicts.any?
          return add_valuations(choice, anchors.drop(1), sign, first_kind: "reconciliation")
        end
      end

      balance_history = MonarchImport::BalanceHistory.new(history: history, flows: flows, closed: choice.closed,
        existing_valuations: existing_valuations, existing_flows: existing_flows)
      anchors = anchors_for(balance_history, choice, current_balance)
      @conflicts[choice.name] = balance_history.conflicts if balance_history.conflicts.any?
      add_valuations(choice, anchors, sign, first_kind: "reconciliation")
    end

    # The family's date, but never later than the server's: Sure leaves entries
    # dated after Date.current out of the balance until that day arrives.
    def default_today
      [ Time.current.in_time_zone(family.resolved_time_zone).to_date, Date.current ].min
    end

    def anchors_for(balance_history, choice, current_balance)
      return balance_history.anchors if current_balance.nil? || choice.closed

      balance_history.anchors_with_current_balance(today, current_balance)
    end

    def add_valuations(choice, anchors, sign, first_kind:)
      anchors.each_with_index do |(date, balance), index|
        opening = index.zero? && first_kind == "opening_anchor"
        @records["Valuation"] << record("Valuation", {
          "id" => "monarch-valuation:#{choice.name}:#{date.iso8601}",
          "account_id" => self.class.source_id(choice.name),
          "date" => date.iso8601,
          "amount" => money(balance * sign),
          "kind" => opening ? "opening_anchor" : "reconciliation",
          "name" => opening ? "Opening balance" : "Balance from Monarch"
        })
      end
    end

    def convert_categories_tags_and_merchants
      existing_categories = family.categories.where(name: @categories.keys).index_by(&:name)
      @stats["categories_reusing_existing"] = 0
      @categories.sort.each do |name, id|
        data = { "id" => id, "name" => name }
        if (category = existing_categories[name])
          data.merge!("color" => category.color, "lucide_icon" => category.lucide_icon,
            "classification_unused" => category.classification_unused)
          @stats["categories_reusing_existing"] += 1
        end
        @records["Category"] << record("Category", data)
      end

      @tags.sort.each { |name, id| @records["Tag"] << record("Tag", { "id" => id, "name" => name }) }

      existing_merchants = family.merchants.where(name: @merchants.keys).index_by(&:name)
      @merchants.sort.each do |name, id|
        data = { "id" => id, "name" => name }
        if (merchant = existing_merchants[name])
          data.merge!("color" => merchant.color, "logo_url" => merchant.logo_url)
          @stats["merchants_reusing_existing"] += 1
        end
        @records["Merchant"] << record("Merchant", data)
      end
    end

    def record(type, data)
      { "type" => type, "data" => data }
    end

    # Two decimals, rounding half to even like the Monarch to Sure tool, and
    # never "-0.00".
    def money(value)
      rounded = value.to_d.round(2, BigDecimal::ROUND_HALF_EVEN)
      whole, fraction = rounded.abs.to_s("F").split(".")
      "#{'-' if rounded.negative?}#{whole}.#{fraction.to_s.ljust(2, '0')}"
    end
end
