require_relative "../../ingestion/record"

# A fetch result is data, never a command to prune. `complete` describes the entire
# requested scope, not merely HTTP success or the end of a page. Only the runtime
# may advance a checkpoint, after durable processing of this batch succeeds.
require "date"

class Provider::AccountData::Page
  attr_reader :records, :next_cursor, :checkpoint_cursor, :progress_cursor, :complete, :mode, :removed_ids, :coverage, :warnings, :evidence

  def initialize(records:, complete:, mode: "delta", next_cursor: nil, checkpoint_cursor: nil, progress_cursor: nil, removed_ids: [], coverage: {}, warnings: [], evidence: {})
    unless records.is_a?(Array) && records.all? { |record| record.is_a?(Ingestion::Record) }
      raise ArgumentError, "records must be an array of normalized Record values"
    end
    raise ArgumentError, "complete must be boolean" unless [ true, false ].include?(complete)
    raise ArgumentError, "mode must be delta or snapshot" unless %w[delta snapshot].include?(mode)
    unless [ next_cursor, checkpoint_cursor, progress_cursor ].all? { |cursor| cursor.nil? || (cursor.is_a?(String) && !cursor.empty?) }
      raise ArgumentError, "cursors must be opaque strings or nil"
    end
    raise ArgumentError, "a complete result cannot have another page" if complete && !next_cursor.nil?
    raise ArgumentError, "completed results use checkpoint_cursor" if complete && !progress_cursor.nil?
    unless removed_ids.is_a?(Array) && removed_ids.all? { |id| id.is_a?(String) && !id.empty? }
      raise ArgumentError, "removed_ids must contain stable external identifiers"
    end
    raise ArgumentError, "coverage must be a hash" unless coverage.is_a?(Hash)
    raise ArgumentError, "warnings must be an array" unless warnings.is_a?(Array)
    raise ArgumentError, "evidence must be a hash" unless evidence.is_a?(Hash)
    raise ArgumentError, "evidence must contain JSON values or finite decimals" unless evidence_value?(evidence)

    @records = deep_copy(records)
    @next_cursor = next_cursor&.dup&.freeze
    @checkpoint_cursor = checkpoint_cursor&.dup&.freeze
    @progress_cursor = progress_cursor&.dup&.freeze
    @complete = complete
    @mode = mode.dup.freeze
    @removed_ids = deep_copy(removed_ids)
    @coverage = deep_copy(coverage)
    @warnings = deep_copy(warnings)
    @evidence = deep_copy(evidence)
    freeze
  end

  def complete?
    complete
  end

  # Payloads and cursor values may contain private financial data.
  def inspect
    "#<#{self.class.name} records=#{records.size} complete=#{complete?}>"
  end

  private
    def evidence_value?(value)
      case value
      when Hash
        value.all? { |key, item| (key.is_a?(String) || key.is_a?(Symbol)) && evidence_value?(item) }
      when Array
        value.all? { |item| evidence_value?(item) }
      when Float, BigDecimal
        value.finite?
      when String, Integer, TrueClass, FalseClass, NilClass
        true
      else
        false
      end
    end

    def deep_copy(value)
      case value
      when Hash
        value.to_h { |key, item| [ deep_copy(key), deep_copy(item) ] }.freeze
      when Array
        value.map { |item| deep_copy(item) }.freeze
      when String, Date
        value.dup.freeze
      when Ingestion::Record, Integer, TrueClass, FalseClass, NilClass, Symbol
        value
      when Float, BigDecimal
        raise ArgumentError, "page metadata numbers must be finite" unless value.finite?
        value
      else
        raise ArgumentError, "page metadata must contain dates or JSON-compatible data"
      end
    end
end
