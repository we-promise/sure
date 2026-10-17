# frozen_string_literal: true

# Hands a balance's movements over to its statement rows. Before the
# balance had statements, Sure booked them from /v1/transfers rows
# (wise_transfer_<id>, wise_fee_<id>, wise_refund_<id>) and activity rows
# (wise_activity_<id>); its statement rows carry the same movements under
# their own ids. Each such row is matched to the statement row carrying it,
# which takes the row's entries over (WiseAccount::Transactions::Processor
# renames them before it books, so they keep what a person did to them)
# instead of booking the movement a second time:
#
# - a transfer by the statement row's reference ("TRANSFER-<id>") with the
#   sign of its movement, else by a TRANSFER statement row in its currency,
#   of its amount (a payout's gross debit, what a pay-in credited) and
#   within a day of it;
# - an activity by "CARD-<resource id>", else by a statement row of the
#   same sign and amount within a day. Wise documents neither reference
#   format.
#
# A matched row books nothing more ("wise_superseded_by"; the statement row
# names the entries it takes over in "wise_supersedes") and leaves the
# payload once the account has no entry under its ids. While a transfer that
# books, created inside the statements' window, has no statement row, the
# balance keeps its /v1/transfers rows: they keep booking, Sure keeps
# fetching transfers for it, and none leaves. An activity inside the window
# that matches nothing is dropped, as some statement row carries its
# movement; one from before the window stays.
#
# Conversions between the profile's own balances (INTERBALANCE,
# AUTO_CONVERSION) stay on the balance: their rows are verified and link as
# transfers. A statement CONVERSION or *_CROSS_BALANCE row books nothing when
# such a conversion moved the same amount in the same currency and direction
# on this balance within a day.
#
# Wise reuses a transfer's reference on its refund, so statement rows that
# share one get their own ids ("wise_statement_id"): the earliest keeps
# wise_statement_<ref>, a later one wise_statement_<ref>_<type>_<yyyymmdd>
# (its amount is added when that is taken too). An id stays with its row
# once given, and a stored row without one booked under the plain reference
# (.with_booked_ids): a row that turns up later with the reference, such as
# the debit of a refund whose window grew back, gets an id of its own
# rather than taking over the entry the refund booked.
#
# The other marks are worked out again from the rows on every sync.
class WiseItem::StatementMigration
  MARKER_KEYS = %w[wise_superseded_by wise_supersedes wise_statement_id].freeze
  WORKED_OUT_KEYS = %w[wise_superseded_by wise_supersedes].freeze
  # Amounts within this are the same movement.
  TOLERANCE = BigDecimal("0.01")
  TRANSFER_DETAILS_TYPE = "TRANSFER"

  # rows: what is left of the payload; counts: transfers_matched,
  # activities_matched, conversions_matched, transfers_unmatched (booked
  # transfers inside the window without a statement row), activities_unmatched
  # (booked activities dropped without one) and retired.
  Result = Data.define(:rows, :counts)

  # The stored statement rows of a balance with the id each booked under:
  # one without an id booked under its plain reference, as Sure gave that id
  # to the only, else the earliest, row with a reference (an older build
  # kept one row per reference). Of several such rows only that one keeps
  # it.
  def self.with_booked_ids(statement_rows)
    unmarked = statement_rows.select { |row| row["wise_statement_id"].blank? && row["referenceNumber"].present? }
    marked = statement_rows.filter_map { |row| row["wise_statement_id"].presence }.to_set
    booked = unmarked.group_by { |row| row["referenceNumber"] }.filter_map do |reference, rows|
      earliest_first(rows).first unless marked.include?(reference)
    end.to_set.compare_by_identity
    statement_rows.map { |row| booked.include?(row) ? row.merge("wise_statement_id" => row["referenceNumber"]) : row }
  end

  # Rows by time, the debit first among rows at the same time.
  def self.earliest_first(rows)
    rows.each_with_index.sort_by do |row, index|
      [ WiseStatement::Processor.posted_at(row)&.to_f || Float::INFINITY, row["type"].to_s == "DEBIT" ? 0 : 1, index ]
    end.map(&:first)
  end

  # rows: the balance's merged payload. window: its statement coverage,
  # { from:, through: } UTC times, or nil. entry_ids: a callable that tells
  # which of the given external ids the balance's account has entries for;
  # nil when the balance is not linked, and then no row leaves.
  def initialize(wise_account, rows, own_recipient_ids:, window:, entry_ids: nil)
    @wise_account = wise_account
    @rows = Array(rows).map { |row| row.except(*WORKED_OUT_KEYS) }
    @own_recipient_ids = own_recipient_ids
    @window = window
    @entry_ids = entry_ids
    @transfer_bookings = {}.compare_by_identity
    @activity_bookings = {}.compare_by_identity
    @times = {}.compare_by_identity
  end

  def call
    statements = @rows.select { |row| row["wise_statement"].present? }
    transfers = @rows.select { |row| transfer_row?(row) }
    conversions, activities = @rows.select { |row| activity_row?(row) }
                                   .partition { |row| WiseActivity::Processor::TWO_LEG_TYPES.include?(row["type"].to_s) }

    assign_statement_ids(statements)
    conversions_matched = mark_conversions(statements, conversions)
    index_free(statements.reject { |row| superseded?(row) })
    match_transfers_by_reference(transfers)
    match_activities_by_reference(activities)
    match_transfers_by_amount(transfers)
    match_activities_by_amount(activities)

    unmatched = transfers.select { |row| !superseded?(row) && transfer_booking(row)[:books] && inside_window?(transfer_booking(row)[:at]) }
    dropped = activities.select { |row| !superseded?(row) && inside_window?(activity_time(row)) }
    retired = retirable((unmatched.empty? ? transfers : []) + activities)
    gone = Set.new.compare_by_identity.merge(dropped + retired)

    Result.new(
      rows: @rows.reject { |row| gone.include?(row) },
      counts: {
        transfers_matched: transfers.count { |row| superseded?(row) },
        activities_matched: activities.count { |row| superseded?(row) },
        conversions_matched: conversions_matched,
        transfers_unmatched: unmatched.size,
        activities_unmatched: dropped.count { |row| activity_booking(row) },
        retired: retired.size
      }
    )
  end

  private

    def transfer_row?(row)
      row["wise_statement"].blank? && !activity_row?(row) && row["id"].present?
    end

    def activity_row?(row)
      WiseActivity::Processor.activity_row?(row)
    end

    def superseded?(row)
      row["wise_superseded_by"].present?
    end

    # A row keeps the id it has. Of the others, the earliest with a
    # reference gets it as its id unless a row already has that; rows at the
    # same time put the debit first.
    def assign_statement_ids(statements)
      statements.group_by { |row| row["referenceNumber"].presence }.each do |reference, rows|
        next if reference.nil?

        taken = rows.filter_map { |row| row["wise_statement_id"].presence }.to_set
        self.class.earliest_first(rows.reject { |row| row["wise_statement_id"].present? }).each do |row|
          # The plain reference, while no row has it, needs no mark.
          next if taken.add?(reference)

          base = [ reference, row["type"].to_s.upcase.presence, statement_time(row)&.strftime("%Y%m%d") ].compact.join("_")
          base = "#{base}_#{statement_amount(row).abs.to_s('F')}" if taken.include?(base)
          id = base
          counter = 1
          id = "#{base}_#{counter += 1}" while taken.include?(id)
          taken << id
          row["wise_statement_id"] = id
        end
      end
    end

    # A statement row of a move between the profile's balances books nothing
    # when a conversion's leg on this balance carries it.
    def mark_conversions(statements, conversions)
      legs = conversions.filter_map do |row|
        booking = activity_booking(row)
        booking&.merge(at: activity_time(row))
      end
      legs_by_cents = legs.group_by { |leg| [ leg[:currency], cents(leg[:amount]) ] }
      taken = Set.new.compare_by_identity

      by_time(statements.select { |row| balance_move?(row) }) { |row| statement_time(row) }.count do |row|
        candidates = near(legs_by_cents, statement_currency(row), statement_amount(row)).select do |leg|
          !taken.include?(leg) && same_movement?(row, leg[:currency], leg[:amount], leg[:at])
        end
        leg = closest(candidates, statement_time(row)) { |candidate| candidate[:at] }
        next false unless leg

        taken << leg
        row["wise_superseded_by"] = leg[:external_id]
        true
      end
    end

    def balance_move?(row)
      type = row.dig("details", "type").to_s
      type == "CONVERSION" || type.end_with?("CROSS_BALANCE")
    end

    # The statement rows no movement has claimed yet, by reference and by
    # currency and amount in cents (TOLERANCE is a cent), so matching stays
    # linear however long the balance's history grows.
    def index_free(statements)
      @free = Set.new.compare_by_identity.merge(statements)
      @free_by_reference = statements.group_by { |row| row["referenceNumber"].presence }
      @free_by_cents = statements.group_by { |row| [ statement_currency(row), cents(statement_amount(row)) ] }
    end

    def free_with_reference(reference)
      Array(@free_by_reference[reference]).select { |row| @free.include?(row) }
    end

    def free_near(currency, amount)
      near(@free_by_cents, currency, amount).select { |row| @free.include?(row) }
    end

    # What an index by [currency, cents] holds within a cent of the amount.
    def near(index, currency, amount)
      center = cents(amount)
      (center - 1..center + 1).flat_map { |key| Array(index[[ currency, key ]]) }
    end

    def cents(amount)
      (amount.abs * 100).round
    end

    # TRANSFER-<id> names the transfer: its earliest row with the sign of
    # the transfer's own movement takes it over, and a refunded payout's
    # refund credit, which shares the reference, its refund entry. When the
    # payout was made before the statements' window, only that credit is
    # in it; it then books nothing, as the transfer's row keeps booking the
    # payout, its fee and the refund (or, without a refund it knows of,
    # none of them). Any other row of the wrong sign books on its own.
    def match_transfers_by_reference(transfers)
      transfers.each do |transfer|
        id = transfer["id"].to_s
        candidates = free_with_reference("TRANSFER-#{id}")
        next if candidates.empty?

        booking = transfer_booking(transfer)
        main = by_time(candidates.select { |row| transfer_sign_fits?(row, booking) }) { |row| statement_time(row) }.first
        refund = by_time(candidates.select { |row| !row.equal?(main) && statement_amount(row).positive? }) { |row| statement_time(row) }.first
        if main
          take_over(transfer, main, "main" => "wise_transfer_#{id}", "fee" => "wise_fee_#{id}")
          take_over(nil, refund, "main" => "wise_refund_#{id}") if refund && booking[:refund]
        elsif refund && booking[:refunded]
          give_way(refund, "wise_refund_#{id}")
        end
      end
    end

    def match_transfers_by_amount(transfers)
      waiting = transfers.select { |row| !superseded?(row) && transfer_booking(row)[:books] && transfer_booking(row)[:at] }
      by_time(waiting) { |row| transfer_booking(row)[:at] }.each do |transfer|
        booking = transfer_booking(transfer)
        candidates = free_near(booking[:currency], booking[:amount]).select do |row|
          row.dig("details", "type") == TRANSFER_DETAILS_TYPE && transfer_sign_fits?(row, booking) &&
            (statement_amount(row).abs - booking[:amount]).abs <= TOLERANCE && within_a_day?(statement_time(row), booking[:at])
        end
        statement = closest(candidates, booking[:at]) { |row| statement_time(row) }
        id = transfer["id"].to_s
        take_over(transfer, statement, "main" => "wise_transfer_#{id}", "fee" => "wise_fee_#{id}") if statement
      end
    end

    def match_activities_by_reference(activities)
      by_time(activities) { |row| activity_time(row) }.each do |activity|
        resource_id = activity.dig("resource", "id").to_s
        next if resource_id.blank?

        booking = activity_booking(activity)
        candidates = free_with_reference("CARD-#{resource_id}").select do |row|
          booking.nil? || statement_amount(row).negative? == booking[:amount].positive?
        end
        statement = by_time(candidates) { |row| statement_time(row) }.first
        take_over(activity, statement, "main" => "wise_activity_#{activity['id']}") if statement
      end
    end

    def match_activities_by_amount(activities)
      by_time(activities) { |row| activity_time(row) }.each do |activity|
        booking = activity_booking(activity)
        at = activity_time(activity)
        next if superseded?(activity) || booking.nil? || at.nil?

        candidates = free_near(booking[:currency], booking[:amount]).select do |row|
          !balance_move?(row) && same_movement?(row, booking[:currency], booking[:amount], at)
        end
        statement = closest(candidates, at) { |row| statement_time(row) }
        take_over(activity, statement, "main" => booking[:external_id]) if statement
      end
    end

    def take_over(row, statement, supersedes)
      @free.delete(statement)
      statement["wise_supersedes"] = supersedes
      row["wise_superseded_by"] = "wise_statement_#{WiseStatement::Processor.transaction_id(statement)}" if row
    end

    # The statement row books nothing: the entry another row books carries
    # its movement.
    def give_way(statement, external_id)
      @free.delete(statement)
      statement["wise_superseded_by"] = external_id
    end

    # Rows a statement row took over leave once the account has no entry
    # under their ids any more (renamed by the processing that followed).
    def retirable(rows)
      superseded = rows.select { |row| superseded?(row) }
      return [] if superseded.empty? || @entry_ids.nil?

      ids = {}.compare_by_identity
      superseded.each { |row| ids[row] = legacy_external_ids(row) }
      existing = @entry_ids.call(ids.values.flatten.uniq).to_set
      superseded.reject { |row| ids[row].any? { |id| existing.include?(id) } }
    end

    def legacy_external_ids(row)
      return [ "wise_activity_#{row['id']}" ] if activity_row?(row)

      %w[transfer fee refund].map { |kind| "wise_#{kind}_#{row['id']}" }
    end

    # What a transfer moved on the balance, as WiseEntry::Processor books it.
    def transfer_booking(row)
      @transfer_bookings[row] ||= begin
        direction = WiseEntry::Processor.direction(row, own_recipient_ids: @own_recipient_ids)
        incoming = direction == :incoming
        refunded = !incoming && row["status"] == WiseEntry::Processor::REFUNDED_STATUS
        {
          incoming: incoming,
          books: WiseEntry::Processor.skip_reason(row, direction: direction).nil?,
          currency: (incoming ? row["targetCurrency"] : row["sourceCurrency"]).presence || @wise_account.currency,
          amount: incoming ? row["targetValue"].to_d.abs : row["sourceValue"].to_d.abs + WiseEntry::Processor.fee(row),
          at: readable { WiseEntry::Processor.created_at(row) },
          refunded: refunded,
          # The transfer books a refund entry (WiseEntry::Processor.refund).
          refund: refunded && WiseEntry::Processor.refund(row).present?
        }
      end
    end

    # What an activity books on the balance, as WiseActivity::Processor
    # does, or nil.
    def activity_booking(row)
      return @activity_bookings[row] if @activity_bookings.key?(row)

      @activity_bookings[row] = readable { WiseActivity::Processor.new(row, wise_account: @wise_account).booking }
    end

    def activity_time(row)
      @times.fetch(row) { @times[row] = readable { WiseActivity::Processor.created_at(row) } }
    end

    # Rows in the order of the time the block gives, rows without one last.
    def by_time(rows)
      rows.each_with_index.sort_by { |row, index| [ yield(row)&.to_f || Float::INFINITY, index ] }.map(&:first)
    end

    def transfer_sign_fits?(statement, booking)
      booking[:incoming] ? statement_amount(statement).positive? : statement_amount(statement).negative?
    end

    # amount has Sure's sign: positive (money out) matches a debit row.
    def same_movement?(statement, currency, amount, at)
      amount.nonzero? && statement_currency(statement) == currency &&
        statement_amount(statement).negative? == amount.positive? &&
        (statement_amount(statement).abs - amount.abs).abs <= TOLERANCE &&
        within_a_day?(statement_time(statement), at)
    end

    def within_a_day?(time, other)
      time.present? && other.present? && (time.to_date - other.to_date).abs <= 1
    end

    # The statements' window ends where they last reached: Wise may have
    # refused them since, and then no statement row carries what came after.
    def inside_window?(time)
      @window.present? && time.present? && time >= @window[:from] && (@window[:through].nil? || time <= @window[:through])
    end

    # The candidate nearest in time (the block gives its time) to `at`.
    def closest(candidates, at)
      candidates.min_by do |candidate|
        time = yield(candidate)
        [ time && at ? (time - at).abs : Float::INFINITY, time&.to_f || Float::INFINITY ]
      end
    end

    def statement_amount(row)
      row.dig("amount", "value").to_d
    end

    def statement_currency(row)
      row.dig("amount", "currency").presence || @wise_account.currency
    end

    def statement_time(row)
      @times.fetch(row) { @times[row] = WiseStatement::Processor.posted_at(row) }
    end

    # nil for a row the processors cannot read (they raise ArgumentError).
    def readable
      yield
    rescue ArgumentError
      nil
    end
end
