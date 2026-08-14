class Rule::ActionExecutor::SplitTransaction < Rule::ActionExecutor
  MODES = [ "fixed", "percentage" ].freeze
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

  def tag_options
    family.tags.alphabetically.pluck(:name, :id)
  end

  def value_display(value)
    config = self.class.parse_config(value)
    return nil unless config

    mode_key = config["mode"] == "percentage" ? "mode_percentage" : "mode_fixed"
    mode_label = I18n.t("rules.actions.split.#{mode_key}")
    I18n.t("rules.actions.split.summary", count: config["splits"].size, mode: mode_label)
  end

  def execute(transaction_scope, value: nil, ignore_attribute_locks: false, rule_run: nil)
    config = self.class.parse_config(value)
    return 0 unless config

    scope = transaction_scope.with_entry
    # Resolved once per rule application (not per transaction) since the scope shares one family.
    family_ids = {
      categories: family.categories.pluck(:id).to_set,
      merchants: family.merchants.pluck(:id).to_set,
      tags: family.tags.pluck(:id).to_set
    }

    unless ignore_attribute_locks
      # Filter by entry's locked_attributes, not transaction's
      # Since excluded is on Entry, not Transaction, we need to check entries.locked_attributes
      scope = scope.where.not(
        Arel.sql("entries.locked_attributes ? 'excluded'")
      )
    end

    count_modified_resources(scope) do |txn|
      next false unless txn.splittable?

      entry = txn.entry
      splits = self.class.build_splits(config, entry.amount, family_ids)
      next false unless splits

      begin
        entry.split!(splits)
        entry.sync_account_later
        true
      rescue ActiveRecord::RecordInvalid
        false
      end
    end
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
      mode = config["mode"]
      splits = config["splits"]

      errors << [ :invalid_mode, {} ] unless MODES.include?(mode)

      unless splits.is_a?(Array) && splits.size.between?(MIN_SPLITS, MAX_SPLITS)
        errors << [ :invalid_split_count, { min: MIN_SPLITS, max: MAX_SPLITS } ]
        return errors
      end

      family_category_ids = family.categories.pluck(:id).to_set
      family_merchant_ids = family.merchants.pluck(:id).to_set
      family_tag_ids = family.tags.pluck(:id).to_set

      total_share = 0
      splits.each_with_index do |split, index|
        name = split["name"]
        share = parse_decimal(split["share"])
        category_id = split["category_id"].presence
        merchant_id = split["merchant_id"].presence
        tag_ids = Array(split["tag_ids"]).reject(&:blank?)
        position = index + 1

        errors << [ :split_name_required, { index: position } ] if name.blank?
        errors << [ :split_name_too_long, { index: position } ] if name.to_s.length > 255

        if share.nil? || share <= 0
          errors << [ :split_share_invalid, { index: position } ]
        else
          total_share += share
        end

        if category_id && !family_category_ids.include?(category_id)
          errors << [ :split_category_invalid, { index: position } ]
        end

        if merchant_id && !family_merchant_ids.include?(merchant_id)
          errors << [ :split_merchant_invalid, { index: position } ]
        end

        if tag_ids.any? && !tag_ids.to_set.subset?(family_tag_ids)
          errors << [ :split_tags_invalid, { index: position } ]
        end
      end

      if mode == "percentage" && errors.empty? && (total_share - 100).abs > PERCENTAGE_TOTAL_TOLERANCE
        errors << [ :percentages_must_total_100, { total: total_share } ]
      end

      errors
    end

    # Parses the JSON value without raising. Returns nil if malformed or structurally incomplete.
    def parse_config(value)
      config = parse_config_strict(value)
      return nil unless config
      return nil unless MODES.include?(config["mode"])
      return nil unless config["splits"].is_a?(Array) && config["splits"].size >= MIN_SPLITS

      config
    end

    # Stage 2: translates the rule's static config into concrete Entry#split! input for one
    # specific matching transaction. Returns nil if the config can't be applied to this amount
    # (e.g. fixed amounts don't sum to this transaction's total) rather than raising, so the
    # caller can skip just this transaction and keep processing the rest of the scope.
    def build_splits(config, entry_amount, family_ids)
      mode = config["mode"]
      raw_splits = config["splits"]
      sign = entry_amount.negative? ? -1 : 1
      total_magnitude = entry_amount.abs

      # Ids are re-resolved against current family state (passed in by the caller, resolved once
      # per rule application) rather than trusting the cached JSON — any of them may have been
      # deleted since the rule was saved.
      family_category_ids = family_ids[:categories]
      family_merchant_ids = family_ids[:merchants]
      family_tag_ids = family_ids[:tags]

      case mode
      when "fixed"
        amounts = raw_splits.map { |s| parse_decimal(s["share"]) }
        return nil if amounts.any?(&:nil?)
        return nil unless amounts.sum == total_magnitude
      when "percentage"
        percentages = raw_splits.map { |s| parse_decimal(s["share"]) }
        return nil if percentages.any?(&:nil?)

        amounts = []
        remaining = total_magnitude
        percentages.each_with_index do |pct, index|
          if index == percentages.size - 1
            amounts << remaining
          else
            share_amount = (total_magnitude * pct / 100).round(2)
            amounts << share_amount
            remaining -= share_amount
          end
        end

        # The last split absorbs whatever's left after rounding the others to cents, which can
        # go non-positive if per-row rounding drift stacks up (many splits, large amount, tiny
        # trailing percentage). Bail rather than create a zero/negative-amount child entry.
        return nil if amounts.any? { |amount| amount <= 0 }
      else
        return nil
      end

      raw_splits.each_with_index.map do |split, index|
        category_id = split["category_id"].presence
        category_id = nil unless category_id && family_category_ids.include?(category_id)

        merchant_id = split["merchant_id"].presence
        merchant_id = nil unless merchant_id && family_merchant_ids.include?(merchant_id)

        tag_ids = Array(split["tag_ids"]).reject(&:blank?) & family_tag_ids.to_a

        {
          name: split["name"],
          amount: amounts[index] * sign,
          category_id: category_id,
          merchant_id: merchant_id,
          tag_ids: tag_ids
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

      def parse_decimal(value)
        return nil if value.blank?

        BigDecimal(value.to_s)
      rescue ArgumentError, TypeError
        nil
      end
  end
end
