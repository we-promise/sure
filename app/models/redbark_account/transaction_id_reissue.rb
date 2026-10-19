# frozen_string_literal: true

# Finds the transactions a bank re-issued under a new id between two syncs.
#
# Redbark passes bank ids through unchanged, and some banks re-issue them: the
# description is shortened and a new id appears while the old one stops being
# served, or the bank sends no ids for a while and Fiskil generates
# `bank_tx_s_` ones. Entries are keyed by id, so without this each re-issue
# imports a second entry.
#
# Within one sync, a stored posted row that vanished from the fetch window is
# paired with a newly seen row only when the two agree on amount, sit at most
# MAX_DATE_GAP days apart, are related (equal real references, or else one
# description is a prefix of the other) and each is the other's only candidate.
# Anything ambiguous is left alone, so the worst case is today's duplicate.
class RedbarkAccount::TransactionIdReissue
  include RedbarkAccount::DataHelpers

  GENERATED_ID_PREFIX = "bank_tx_s_"
  MAX_DATE_GAP = 3
  # "0" is a placeholder on provisional rows, never a real reference
  PLACEHOLDER_REFERENCES = [ "0" ].freeze

  # re_keys: [old_id, new_id] pairs where the entry should follow the new id.
  # aliases: [kept_id, generated_id] pairs where the entry keeps its id.
  Result = Data.define(:re_keys, :aliases)

  def initialize(stored:, fetched:, window_start:, known_alias_ids: [])
    @stored = stored.map { |t| normalize(t) }
    @fetched = fetched.map { |t| normalize(t) }
    @window_start = window_start
    @known_alias_ids = known_alias_ids.map(&:to_s).to_set
  end

  def call
    re_keys = []
    aliases = []

    pairs.each do |vanished, replacement|
      if replacement[:id].start_with?(GENERATED_ID_PREFIX)
        aliases << [ vanished[:id], replacement[:id] ]
      else
        re_keys << [ vanished[:id], replacement[:id] ]
      end
    end

    Result.new(re_keys: re_keys, aliases: aliases)
  end

  private

    def pairs
      return [] if @window_start.nil?

      candidates = vanished_rows.index_with do |vanished|
        new_rows.select { |row| same_transaction?(vanished, row) }
      end

      candidates.filter_map do |vanished, matches|
        next unless matches.one?

        replacement = matches.first
        next unless candidates.count { |_, other| other.include?(replacement) } == 1

        [ vanished, replacement ]
      end
    end

    def vanished_rows
      fetched_ids = @fetched.map { |t| t[:id] }.to_set

      @stored.select do |t|
        posted?(t) && t[:date].present? && t[:date] >= @window_start && !fetched_ids.include?(t[:id])
      end
    end

    def new_rows
      stored_ids = @stored.map { |t| t[:id] }.to_set

      @fetched.select do |t|
        posted?(t) && t[:date].present? && !stored_ids.include?(t[:id]) && !@known_alias_ids.include?(t[:id])
      end
    end

    def same_transaction?(vanished, row)
      vanished[:amount].present? && vanished[:amount] == row[:amount] &&
        (vanished[:date] - row[:date]).abs <= MAX_DATE_GAP &&
        related?(vanished, row)
    end

    def related?(a, b)
      if a[:reference] && b[:reference]
        a[:reference] == b[:reference]
      else
        x, y = a[:description], b[:description]
        x.present? && y.present? && (x.start_with?(y) || y.start_with?(x))
      end
    end

    def posted?(t)
      t[:id].present? && t[:status] != "pending"
    end

    def normalize(transaction)
      t = transaction.with_indifferent_access
      reference = t[:reference].to_s.strip

      {
        id: t[:id].to_s,
        status: t[:status].to_s,
        date: safe_date(t[:date] || t[:postDate]),
        amount: safe_decimal(t[:amount]),
        description: t[:description].to_s.squish.downcase,
        reference: reference.blank? || PLACEHOLDER_REFERENCES.include?(reference) ? nil : reference
      }
    end

    def safe_decimal(value)
      parse_decimal(value)
    rescue ArgumentError
      nil
    end

    def safe_date(value)
      parse_date(value)
    rescue ArgumentError
      nil
    end
end
