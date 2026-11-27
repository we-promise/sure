class Rule::ActionExecutor::SplitTransaction < Rule::ActionExecutor
  # Per-split type, not a single mode for the whole action: a fixed split takes a literal
  # amount off the top, a percentage split takes a share of whatever's left after all fixed
  # splits are subtracted. Fixed splits are always resolved first, regardless of row order.
  TYPES = [ "fixed", "percentage" ].freeze
  # entries.amount is decimal(19,4).
  AMOUNT_SCALE = 4
  REFERENCE_ERRORS = { category: :split_category_invalid, merchant: :split_merchant_invalid, tag: :split_tags_invalid }.freeze
  MIN_SPLITS = 2
  MAX_SPLITS = 20
  PERCENTAGE_TOTAL_TOLERANCE = 0.01

  def type
    "split"
  end

  # Overrides the base class's nil (the `options` contract is for "select"-type executors,
  # which the split type isn't). Keeping it nil avoids duplicating the full category list into
  # every action row's data-rule--actions-action-executors-value attribute.
  def options
    nil
  end

  def category_options
    family.categories.alphabetically.pluck(:name, :id)
  end

  def merchant_options
    family.merchants.alphabetically.pluck(:name, :id)
  end

  # Records, not [name, id] pairs: DS::TagSelect renders each tag's color.
  def tag_records
    family.tags.alphabetically
  end

  def value_display(value)
    config = self.class.parse_config(value)
    return nil unless config

    I18n.t("rules.actions.split.summary", count: config["splits"].size)
  end

  def execute(transaction_scope, value: nil, ignore_attribute_locks: false, rule_run: nil)
    config = self.class.parse_config(value)
    return 0 unless config

    # Children of an earlier split and excluded entries are never splittable;
    # filtering them here saves a splittable? check per row on every run.
    scope = transaction_scope.with_entry.where(entries: { parent_entry_id: nil, excluded: false })
    # Resolved once per rule application (not per transaction) since the scope shares one family.
    references = Entry::SplitReferences.new(family)

    unless ignore_attribute_locks
      # Filter by entry's locked_attributes, not transaction's
      # Since excluded is on Entry, not Transaction, we need to check entries.locked_attributes
      scope = scope.where.not(
        Arel.sql("entries.locked_attributes ? 'excluded'")
      )
    end

    skipped = []

    modified_count = count_modified_resources(scope) do |txn|
      next false unless txn.splittable?

      entry = txn.entry
      splits = self.class.build_splits(config, entry.amount, references, precision: self.class.amount_precision(entry.currency))

      if splits.nil?
        skipped << { transaction_id: txn.id, entry_id: entry.id, reason: "unresolvable_split_amounts", entry_amount: entry.amount.to_s }
        next false
      end

      begin
        # Two split rules (or a manual apply and a queued run) can reach the
        # same transaction at once; split_once! locks the parent and skips it
        # if the other run already split it (or it was excluded meanwhile).
        # The lock keeps rules further down from overwriting the children's categories.
        next false unless entry.split_once!(splits, lock_attributes: true)

        entry.sync_account_later
        true
      rescue ActiveRecord::RecordInvalid => e
        skipped << { transaction_id: txn.id, entry_id: entry.id, reason: "record_invalid", errors: e.record.errors.full_messages }
        false
      end
    end

    log_skipped_transactions(skipped, rule_run:) if skipped.any?

    modified_count
  end

  class << self
    # Stage 1 validation: static structural checks that don't depend on any particular
    # matching transaction's amount. Used by Rule::Action to reject bad configs at save time.
    # Returns an array of [i18n_key, interpolation_options] tuples (empty when valid), so the
    # caller can render translated messages via errors.add(:value, key, **options).
    def config_errors(value, family:)
      config = parse_config_strict(value)
      return [ [ :invalid_config, {} ] ] unless config

      errors = []
      splits = config["splits"]

      unless splits.is_a?(Array) && splits.size.between?(MIN_SPLITS, MAX_SPLITS)
        errors << [ :invalid_split_count, { min: MIN_SPLITS, max: MAX_SPLITS } ]
        return errors
      end

      references = Entry::SplitReferences.new(family)

      total_percentage = 0
      has_percentage = false

      # Rows come from a JSON blob, so a crafted request can put anything here (e.g. null).
      # Reject non-object rows up front rather than raising on split["name"] below.
      unless splits.all? { |split| split.is_a?(Hash) }
        errors << [ :invalid_config, {} ]
        return errors
      end

      splits.each_with_index do |split, index|
        name = split["name"]
        type = split["type"]
        share = parse_decimal(split["share"])
        position = index + 1

        # A NUL byte or broken UTF-8 would only fail once the rule runs and the child is saved.
        # Checked first: blank? raises on broken UTF-8.
        if !DatabaseTextValidator.acceptable?(name)
          errors << [ :split_name_invalid, { index: position } ]
        elsif name.blank?
          errors << [ :split_name_required, { index: position } ]
        elsif name.to_s.length > 255
          errors << [ :split_name_too_long, { index: position } ]
        end
        errors << [ :split_type_invalid, { index: position } ] unless TYPES.include?(type)

        # A fixed share with more decimals than the amount columns hold would
        # be stored rounded, and the children would no longer sum to the parent.
        if share.nil? || share <= 0 || (type == "fixed" && share.round(AMOUNT_SCALE) != share)
          errors << [ :split_share_invalid, { index: position } ]
        elsif type == "percentage"
          has_percentage = true
          total_percentage += share
        end

        unknown = references.unknown(category_id: split["category_id"], merchant_id: split["merchant_id"], tag_ids: split["tag_ids"])
        unknown.map(&:first).uniq.each do |kind|
          errors << [ REFERENCE_ERRORS.fetch(kind), { index: position } ]
        end
      end

      if has_percentage && errors.empty? && (total_percentage - 100).abs > PERCENTAGE_TOTAL_TOLERANCE
        errors << [ :percentages_must_total_100, { total: ActiveSupport::NumberHelper.number_to_rounded(total_percentage, precision: 2, strip_insignificant_zeros: true) } ]
      end

      errors
    end

    # Parses the JSON value without raising. Returns nil if malformed or structurally incomplete.
    def parse_config(value)
      config = parse_config_strict(value)
      return nil unless config
      return nil unless config["splits"].is_a?(Array) && config["splits"].size >= MIN_SPLITS
      return nil unless config["splits"].all? { |split| split.is_a?(Hash) }

      config
    end

    # Rebuilds an imported split config against the importing family. Exports carry names
    # ("category", "merchant", "tags", see Family::DataExporter#portable_split_value) because ids
    # don't survive a move to another family. Each reference is resolved through the block,
    # called as (kind, name:) for a name or (kind, id:) for a raw id, with kind :category,
    # :merchant or :tag; it returns the local id, or nil to drop a stale or foreign id instead of
    # failing the whole import on save. Unparseable values are returned as a string unchanged so
    # Rule::Action's validation can report them.
    def localize_value(value, &resolve)
      raw = value.is_a?(Hash) || value.is_a?(Array) ? value.to_json : value.to_s
      config = parse_config(raw)
      return raw unless config

      splits = config["splits"].map do |split|
        split.except("category", "merchant", "tags").merge(
          "category_id" => localize_reference(split, "category", :category, &resolve),
          "merchant_id" => localize_reference(split, "merchant", :merchant, &resolve),
          "tag_ids" => localize_tags(split, &resolve)
        )
      end

      config.merge("splits" => splits).to_json
    end

    # Digits a percentage share is rounded to: the currency's minor unit (0 for JPY, 3 for KWD),
    # capped at the 4 decimals entries.amount stores (crypto currencies list 8), so children that
    # sum to the parent in memory still do once saved. Unknown codes fall back to cents.
    def amount_precision(currency)
      [ Money::Currency.new(currency).default_precision, AMOUNT_SCALE ].min
    rescue Money::Currency::UnknownCurrencyError
      2
    end

    # True when every text inside an imported split value (row names, category/merchant/tag names)
    # can be stored. A JSON string hides NUL bytes as \u0000 escapes, so it is checked decoded.
    def acceptable_text?(value)
      decoded = value.is_a?(String) ? JSON.parse(value) : value
      DatabaseTextValidator.acceptable?(decoded)
    rescue JSON::ParserError
      DatabaseTextValidator.acceptable?(value)
    end

    # True if the config has at least one percentage-type split. Pure-fixed configs need an
    # exact-amount rule condition (see Rule::Action#split_config_valid); configs with a
    # percentage split don't, since the percentage share(s) always absorb whatever's left after
    # fixed splits, adapting automatically to any matching transaction's amount.
    def has_percentage_split?(config)
      config["splits"].any? { |split| split["type"] == "percentage" }
    end

    # Stage 2: translates the rule's static config into concrete Entry#split! input for one
    # specific matching transaction. Returns nil if the config can't be applied to this amount
    # (e.g. fixed splits don't leave a positive remainder for the percentage splits to divide)
    # rather than raising, so the caller can skip just this transaction and keep processing the
    # rest of the scope.
    #
    # precision comes from amount_precision, so a percentage share never produces a fraction of
    # the currency's smallest unit.
    def build_splits(config, entry_amount, references, precision: 2)
      raw_splits = config["splits"]
      sign = entry_amount.negative? ? -1 : 1
      total_magnitude = entry_amount.abs

      fixed_indices = []
      percentage_indices = []
      raw_splits.each_with_index do |split, index|
        case split["type"]
        when "fixed" then fixed_indices << index
        when "percentage" then percentage_indices << index
        else return nil
        end
      end

      amounts = Array.new(raw_splits.size)

      fixed_total = 0
      fixed_indices.each do |index|
        amount = parse_decimal(raw_splits[index]["share"])
        return nil if amount.nil?
        amounts[index] = amount
        fixed_total += amount
      end

      remaining = total_magnitude - fixed_total

      if percentage_indices.empty?
        # Pure fixed splits only make sense if this transaction's total is exactly the fixed
        # splits' sum — there's nothing dynamic to absorb a mismatch (enforced at save time by
        # requiring a matching exact-amount rule condition, see Rule::Action).
        return nil unless fixed_total == total_magnitude
      else
        # Fixed splits ate more than (or all of) the transaction total, leaving nothing for the
        # percentage splits to divide.
        return nil if remaining <= 0

        percentages = percentage_indices.map { |index| parse_decimal(raw_splits[index]["share"]) }
        return nil if percentages.any?(&:nil?)

        running_remaining = remaining
        percentage_indices.each_with_index do |split_index, position|
          if position == percentage_indices.size - 1
            amounts[split_index] = running_remaining
          else
            share_amount = (remaining * percentages[position] / 100).round(precision)
            amounts[split_index] = share_amount
            running_remaining -= share_amount
          end
        end

        # The last percentage split absorbs whatever's left after rounding the others to the minor unit,
        # which can go non-positive if per-row rounding drift stacks up (many splits, large
        # amount, tiny trailing percentage). Bail rather than create a zero/negative-amount
        # child entry.
        return nil if percentage_indices.any? { |index| amounts[index] <= 0 }
      end

      # Ids are re-resolved against current family state (references, built once per rule
      # application) rather than trusting the cached JSON, since any of them may have been
      # deleted since the rule was saved.
      raw_splits.each_with_index.map do |split, index|
        {
          name: split["name"],
          amount: amounts[index] * sign,
          **references.scope(category_id: split["category_id"], merchant_id: split["merchant_id"], tag_ids: split["tag_ids"])
        }
      end
    end

    private
      def parse_config_strict(value)
        return nil if value.blank?

        parsed = JSON.parse(value)
        return nil unless parsed.is_a?(Hash)

        parsed
      rescue JSON::ParserError
        nil
      end

      def localize_reference(split, key, kind)
        name = split[key].to_s.strip
        return yield(kind, name: name) if name.present?

        id = split["#{key}_id"].to_s.strip.downcase
        yield(kind, id: id) if id.present?
      end

      # Tags may also come as one comma-separated string, like set_transaction_tags values.
      def localize_tags(split)
        ids = if split.key?("tags")
          names = split["tags"].is_a?(String) ? Rule::Action.decode_multi_value_names(split["tags"]) : Array(split["tags"])
          names.map { |name| name.to_s.strip }.reject(&:blank?).map { |name| yield(:tag, name: name) }
        else
          Array(split["tag_ids"]).map { |id| id.to_s.strip.downcase }.reject(&:blank?).map { |id| yield(:tag, id: id) }
        end

        ids.compact.uniq
      end

      # Non-finite values ("NaN", "Infinity") parse fine but can never be a real share, and NaN
      # slips past `share <= 0`, so treat them as unparseable.
      def parse_decimal(value)
        return nil if value.blank?

        decimal = BigDecimal(value.to_s)
        decimal.finite? ? decimal : nil
      rescue ArgumentError, TypeError
        nil
      end
  end

  private
    # One summary entry per rule application (not one per skipped transaction) so a
    # misconfigured split action against a large matching scope can't flood the debug log.
    def log_skipped_transactions(skipped, rule_run:)
      DebugLogEntry.capture(
        category: "rule_run",
        level: "warn",
        message: "split_transaction skipped #{skipped.size} transaction(s)",
        source: self.class.name,
        family: family,
        metadata: {
          rule_id: rule.id,
          rule_run_id: rule_run&.id,
          skipped_count: skipped.size,
          skipped: skipped.first(20)
        }
      )
    end
end
