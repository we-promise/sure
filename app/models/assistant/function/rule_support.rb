# frozen_string_literal: true

# Shared plumbing for the rule tools (get_rules, get_rule_options,
# preview_rule, create_rule, update_rule, apply_rule).
#
# A rule rewrites every matching transaction, and an active rule runs again on
# every family sync. So the write tools never activate a rule: create_rule and
# update_rule save it inactive, and only apply_rule activates it. apply_rule
# needs a preview_token, which only a preview that listed matching
# transactions issues (preview_rule, create_rule, update_rule; never
# get_rules). The token is bound to the rule's definition and match count, so
# it can't be skipped, reused after an edit, or applied to changed matches.
#
# Allowed values are resolved here from the requesting user rather than from
# the registry's own option lists: those read Current.user, which is nil on the
# assistant and MCP paths.
module Assistant::Function::RuleSupport
  # AI-backed actions cost money per transaction; the web UI shows a cost
  # estimate before applying them, which this surface cannot do yet.
  BLOCKED_ACTION_TYPES = %w[auto_categorize auto_detect_merchants].freeze

  # Ids are resolved to names by these lookups, keyed by condition or action type.
  ACCOUNT_KEYS = %w[transaction_account set_as_transfer_or_payment].freeze
  CATEGORY_KEYS = %w[transaction_category set_transaction_category].freeze
  TAG_KEYS = %w[transaction_tag set_transaction_tags].freeze
  MERCHANT_KEYS = %w[transaction_merchant set_transaction_merchant].freeze

  DEFAULT_SAMPLE_SIZE = 10
  MAX_SAMPLE_SIZE = 25

  PREVIEW_TOKEN_TTL = 30.minutes

  # JSON schema fragments shared by preview_rule, create_rule and update_rule.
  def condition_schema
    {
      type: "object",
      properties: {
        condition_type: {
          type: "string",
          description: "A condition key from get_rule_options, or \"compound\" to group sub_conditions."
        },
        operator: {
          type: "string",
          description: "An operator value from get_rule_options for this condition. For compound: \"and\" or \"or\"."
        },
        value: {
          type: "string",
          description: "Text, number, or an id (account, category, tag, merchant) depending on the condition. Omit for is_null / is_not_null and compound."
        },
        sub_conditions: {
          type: "array",
          description: "Only for compound conditions: one level of plain conditions (no nesting).",
          items: { type: "object" }
        }
      },
      required: %w[condition_type operator]
    }
  end

  def action_schema
    {
      type: "object",
      properties: {
        action_type: {
          type: "string",
          description: "An action key from get_rule_options."
        },
        value: {
          description: "Category/merchant/account id, activity label or new name depending on the action; an array of tag ids for set_transaction_tags. Omit for actions without a value.",
          anyOf: [ { type: "string" }, { type: "array", items: { type: "string" } } ]
        }
      },
      required: %w[action_type]
    }
  end

  def definition_properties
    {
      conditions: {
        type: "array",
        description: "All conditions must match (AND). Use a compound condition with operator \"or\" for alternatives.",
        items: condition_schema
      },
      actions: {
        type: "array",
        description: "At least one action. Each action type may appear once.",
        items: action_schema
      },
      effective_date: {
        type: "string",
        description: "Optional YYYY-MM-DD. The rule only touches transactions on or after this date."
      }
    }
  end

  private
    # Finds a rule in the user's family. Returns nil for unknown or foreign ids.
    def find_rule(id)
      return nil unless valid_uuid?(id)

      family.rules.includes(conditions: :sub_conditions).find_by(id: id)
    end

    # Replaces the rule's conditions and actions with the given definition and
    # returns a list of problems. The rule is not saved. A key that is absent
    # leaves that part of the rule unchanged.
    def assign_definition(rule, params)
      problems = []

      if params.key?("effective_date")
        raw = params["effective_date"]
        if raw.blank?
          rule.effective_date = nil
        else
          begin
            rule.effective_date = Date.iso8601(raw.to_s)
          rescue Date::Error
            problems << "effective_date must be a YYYY-MM-DD date."
          end
        end
      end

      if params.key?("conditions")
        conditions = params["conditions"]
        if conditions.is_a?(Array)
          rule.conditions.each(&:mark_for_destruction)
          conditions.each_with_index do |condition, index|
            problems.concat(build_condition(rule, rule.conditions, condition, "conditions[#{index}]", allow_compound: true))
          end
        else
          problems << "conditions must be an array."
        end
      end

      if params.key?("actions")
        actions = params["actions"]
        if actions.is_a?(Array)
          rule.actions.each(&:mark_for_destruction)
          actions.each_with_index do |action, index|
            problems.concat(build_action(rule, action, "actions[#{index}]"))
          end
        else
          problems << "actions must be an array."
        end
      end

      problems
    end

    def build_condition(rule, collection, attrs, path, allow_compound:)
      return [ "#{path} must be an object." ] unless attrs.is_a?(Hash)

      type = attrs["condition_type"].to_s
      operator = attrs["operator"].to_s

      if type == "compound"
        return [ "#{path}: compound conditions cannot be nested." ] unless allow_compound
        return [ "#{path}: compound operator must be \"and\" or \"or\"." ] unless %w[and or].include?(operator)

        subs = attrs["sub_conditions"]
        return [ "#{path}: compound conditions need at least one sub_condition." ] unless subs.is_a?(Array) && subs.any?

        compound = collection.build(condition_type: "compound", operator: operator)
        return subs.each_with_index.flat_map do |sub, index|
          build_condition(rule, compound.sub_conditions, sub, "#{path}.sub_conditions[#{index}]", allow_compound: false)
        end
      end

      filter = rule.condition_filters.find { |f| f.key == type }
      return [ "#{path}: unknown condition_type '#{type}'. See get_rule_options." ] unless filter

      operators = filter.operators.map(&:last)
      return [ "#{path}: operator '#{operator}' is not valid for #{type}. Valid: #{operators.join(", ")}." ] unless operators.include?(operator)

      value = attrs["value"]
      if Rule::ConditionFilter::VALUELESS_OPERATORS.include?(operator)
        value = nil
      else
        value = value.to_s.strip
        return [ "#{path}: value is required for operator '#{operator}'." ] if value.blank?
        return [ "#{path}: value must be a number." ] if filter.type == "number" && !numeric?(value)

        allowed = allowed_values(type)
        return [ "#{path}: '#{value}' is not a valid value for #{type}. #{value_hint(type)}" ] if allowed && !allowed.include?(value)
      end

      collection.build(condition_type: type, operator: operator, value: value)
      []
    end

    def build_action(rule, attrs, path)
      return [ "#{path} must be an object." ] unless attrs.is_a?(Hash)

      type = attrs["action_type"].to_s
      return [ "#{path}: #{type} calls an AI model and is not available here; add it in Settings > Rules." ] if BLOCKED_ACTION_TYPES.include?(type)

      executor = rule.action_executors.find { |e| e.key == type }
      return [ "#{path}: unknown action_type '#{type}'. See get_rule_options." ] unless executor

      value = attrs["value"]
      case executor.type
      when "function"
        value = nil
      when "multi_select"
        values = Array(value).map { |v| v.to_s.strip }.compact_blank.uniq
        return [ "#{path}: value must list at least one id for #{type}." ] if values.empty?

        invalid = values - allowed_values(type)
        return [ "#{path}: #{invalid.join(", ")} not valid for #{type}. #{value_hint(type)}" ] if invalid.any?

        value = values
      else
        return [ "#{path}: value must be a single string for #{type}." ] if value.is_a?(Array)

        value = value.to_s.strip
        return [ "#{path}: value is required for #{type}." ] if value.blank?

        allowed = allowed_values(type)
        return [ "#{path}: '#{value}' is not a valid value for #{type}. #{value_hint(type)}" ] if allowed && !allowed.include?(value)
      end

      rule.actions.build(action_type: type, value: value)
      []
    end

    # Runs model validations, then builds (without running) each condition's
    # query, which surfaces operators a filter lists but cannot apply (e.g. tag
    # "not equal to"). Returns a list of problems.
    def validate_rule(rule)
      return rule.errors.full_messages unless rule.valid?

      scope = rule.registry.resource_scope
      rule.conditions.reject(&:marked_for_destruction?).each { |c| c.apply(c.prepare(scope)) }
      []
    rescue Rule::ConditionFilter::UnsupportedOperatorError => e
      [ e.message ]
    end

    # nil means free text (no fixed list of values).
    def allowed_values(key)
      case key
      when *ACCOUNT_KEYS then accessible_accounts.pluck(:id).map(&:to_s)
      when *CATEGORY_KEYS then family.categories.pluck(:id).map(&:to_s)
      when *TAG_KEYS then family.tags.pluck(:id).map(&:to_s)
      when "transaction_merchant" then family.available_merchants_for(user).pluck(:id).map(&:to_s)
      when "set_transaction_merchant" then family.merchants.pluck(:id).map(&:to_s)
      when "transaction_type" then %w[income expense transfer]
      when "set_investment_activity_label" then Transaction::ACTIVITY_LABELS
      end
    end

    def value_hint(key)
      case key
      when *ACCOUNT_KEYS then "Use an account id from get_accounts."
      when *CATEGORY_KEYS then "Use a category id from get_categories."
      when *TAG_KEYS then "Use tag ids from get_tags."
      when *MERCHANT_KEYS then "Use a merchant id from get_merchants."
      else "Valid: #{Array(allowed_values(key)).join(", ")}."
      end
    end

    def numeric?(value)
      BigDecimal(value)
      true
    rescue ArgumentError
      false
    end

    def accessible_accounts
      family.accounts.accessible_by(user)
    end

    # Rule in readable form: ids are returned alongside their names.
    def serialize_rule(rule, include_last_run: false)
      data = {
        id: rule.id,
        name: rule.name,
        active: rule.active,
        effective_date: rule.effective_date&.iso8601,
        conditions: rule.conditions.reject(&:marked_for_destruction?).select { |c| c.parent_id.nil? }.map { |c| serialize_condition(rule, c) },
        actions: rule.actions.reject(&:marked_for_destruction?).map { |a| serialize_action(rule, a) },
        updated_at: rule.updated_at&.iso8601
      }

      if include_last_run
        run = rule.rule_runs.recent.first
        data[:last_run] = run && {
          executed_at: run.executed_at.iso8601,
          status: run.status,
          execution_type: run.execution_type,
          transactions_queued: run.transactions_queued,
          transactions_modified: run.transactions_modified
        }
      end

      data
    end

    def serialize_condition(rule, condition)
      if condition.compound?
        {
          condition_type: "compound",
          operator: condition.operator,
          sub_conditions: condition.sub_conditions.map { |sub| serialize_condition(rule, sub) }
        }
      else
        {
          condition_type: condition.condition_type,
          operator: condition.operator,
          value: condition.value,
          value_name: value_name(condition.condition_type, condition.value)
        }.compact
      end
    end

    def serialize_action(rule, action)
      values = action_values(action)
      names = values.map { |v| value_name(action.action_type, v) }.compact

      {
        action_type: action.action_type,
        value: action.value,
        value_name: names.any? ? names.join(", ") : nil
      }.compact
    end

    def action_values(action)
      return [] if action.value.blank?

      action.action_type.in?(TAG_KEYS) ? action.value.to_s.split(",") : [ action.value.to_s ]
    end

    # Name for an id-valued condition or action, or nil for free text. An
    # account the user cannot see is reported without its name.
    def value_name(key, value)
      return nil if value.blank?

      names = name_lookup(key)
      return nil unless names

      names.fetch(value.to_s) { key.in?(ACCOUNT_KEYS) ? "(account not shared with you)" : "(deleted)" }
    end

    def name_lookup(key)
      @name_lookups ||= {}
      group =
        case key
        when *ACCOUNT_KEYS then :accounts
        when *CATEGORY_KEYS then :categories
        when *TAG_KEYS then :tags
        when *MERCHANT_KEYS then :merchants
        end
      return nil unless group

      @name_lookups[group] ||=
        case group
        when :accounts then accessible_accounts.pluck(:id, :name).to_h { |id, name| [ id.to_s, name ] }
        when :categories then family.categories.includes(:parent).to_h { |c| [ c.id.to_s, c.name_with_parent ] }
        when :tags then family.tags.pluck(:id, :name).to_h { |id, name| [ id.to_s, name ] }
        when :merchants then family.available_merchants_for(user).pluck(:id, :name).to_h { |id, name| [ id.to_s, name ] }
        end
    end

    # What applying the rule would touch. The count covers the whole family, as
    # the rule does; the sample only lists transactions in accounts the user
    # can see.
    def preview(rule, sample_size: DEFAULT_SAMPLE_SIZE)
      scope = rule.matching_resources
      match_count = scope.count

      visible = scope.where(entries: { account_id: accessible_accounts.select(:id) })
      sample = visible
        .includes(:category, :merchant, entry: :account)
        .order("entries.date DESC, entries.id DESC")
        .limit(sample_size)

      {
        match_count: match_count,
        visible_match_count: visible.count,
        sample: sample.map { |txn| serialize_sample(txn) },
        actions: rule.actions.reject(&:marked_for_destruction?).map { |a| describe_action(rule, a) },
        preview_token: preview_token(rule, match_count, sample_size: sample_size)
      }.compact
    end

    # Issued for a saved rule when the preview listed matches (a zero
    # sample_size shows none). Signed, and bound to the user, the rule's
    # definition and the match count.
    def preview_token(rule, match_count, sample_size:)
      return nil unless rule.persisted? && rule.changes.empty?
      return nil if sample_size.zero? && match_count.positive?

      preview_verifier.generate(
        { "rule_id" => rule.id, "user_id" => user.id, "definition" => definition_digest(rule), "match_count" => match_count },
        purpose: :apply_rule, expires_in: PREVIEW_TOKEN_TTL
      )
    end

    # The token's payload, or nil when it is missing, forged, expired, or
    # issued to another user or rule.
    def read_preview_token(token, rule)
      payload = preview_verifier.verified(token.to_s, purpose: :apply_rule) if token.present?
      return nil unless payload.is_a?(Hash)
      return nil unless payload["rule_id"] == rule.id && payload["user_id"] == user.id

      payload
    end

    # What the rule would do, independent of timestamps and display names.
    def definition_digest(rule)
      definition = {
        effective_date: rule.effective_date&.iso8601,
        conditions: rule.conditions.reject(&:marked_for_destruction?).select { |c| c.parent_id.nil? }
                        .map { |c| digest_condition(c) }.sort_by(&:to_json),
        actions: rule.actions.reject(&:marked_for_destruction?).map { |a| [ a.action_type, a.value.to_s ] }.sort
      }
      Digest::SHA256.hexdigest(definition.to_json)
    end

    def digest_condition(condition)
      return [ condition.operator, condition.sub_conditions.map { |sub| digest_condition(sub) }.sort_by(&:to_json) ] if condition.compound?

      [ condition.condition_type, condition.operator, condition.value.to_s ]
    end

    def preview_verifier
      Rails.application.message_verifier("assistant/rule_preview")
    end

    def serialize_sample(txn)
      entry = txn.entry
      {
        id: txn.id,
        date: entry.date.iso8601,
        account: entry.account.name,
        name: entry.name,
        amount: entry.amount.to_s,
        currency: entry.currency,
        category: txn.category&.name_with_parent,
        merchant: txn.merchant&.name,
        excluded: entry.excluded
      }
    end

    def describe_action(rule, action)
      serialize_action(rule, action).merge(label: action.executor.label)
    rescue Rule::Registry::UnsupportedActionError
      serialize_action(rule, action)
    end

    def resolved_sample_size(params)
      return DEFAULT_SAMPLE_SIZE if params["sample_size"].blank?

      params["sample_size"].to_i.clamp(0, MAX_SAMPLE_SIZE)
    end

    def error(key, message, **extra)
      { success: false, error: key, message: message }.merge(extra)
    end
end
