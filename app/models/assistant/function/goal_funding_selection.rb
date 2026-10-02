class Assistant::Function::GoalFundingSelection
  MODES = %w[whole_account fixed_amount].freeze

  Selection = Data.define(:accounts, :allocations)

  class Invalid < StandardError
    attr_reader :key, :extras

    def initialize(key, message, extras = {})
      @key = key
      @extras = extras
      super(message)
    end
  end

  def self.schema
    {
      type: "array",
      minItems: 1,
      uniqueItems: true,
      description: "Complete funding list. Each item identifies an accessible Depository or Investment account and explicitly chooses a whole-account claim or a fixed allocation.",
      items: {
        type: "object",
        required: %w[account_id allocation],
        additionalProperties: false,
        properties: {
          account_id: { type: "string", description: "Fundable account ID from get_accounts" },
          allocation: {
            type: "object",
            required: [ "mode" ],
            additionalProperties: false,
            properties: {
              mode: { type: "string", enum: MODES, description: "whole_account claims the unallocated account; fixed_amount reserves one amount" },
              amount: { type: "number", exclusiveMinimum: 0, description: "Required only for fixed_amount; omit for whole_account" }
            }
          }
        }
      }
    }
  end

  def self.fundable_accounts_for(user)
    user.accessible_accounts.where(accountable_type: Goal::FUNDABLE_ACCOUNT_TYPES).visible
  end

  def initialize(user:, family:, raw:, goal: nil)
    @user = user
    @family = family
    @raw = raw
    @goal = goal
  end

  def resolve!
    specs = parse_specs
    ids = specs.map { |spec| spec.fetch(:account_id) }
    accounts_by_id = accessible_accounts.where(id: ids).index_by { |account| account.id.to_s }
    missing_ids = ids - accounts_by_id.keys
    raise Invalid.new("unknown_accounts", "One or more funding account IDs are unavailable.", unknown_ids: missing_ids, available_accounts: available_payload) if missing_ids.any?

    accounts = ids.map { |id| accounts_by_id.fetch(id) }
    currencies = accounts.map(&:currency).uniq
    raise Invalid.new("currency_mismatch", "All funding accounts must share one currency. Found: #{currencies.join(', ')}.") unless currencies.one?

    availability = Goal::FundingAvailability.for(family:, accounts:, excluding_goal: goal)
    claimed_ids = specs.filter_map do |spec|
      next unless spec.dig(:allocation, :mode) == "whole_account"
      spec[:account_id] if availability.fetch(spec[:account_id]).status == Goal::FundingAvailability::WHOLE_ACCOUNT_CLAIMED
    end
    if claimed_ids.any?
      raise Invalid.new(
        "account_claimed_in_full",
        "One or more accounts are already claimed in full. Use fixed_amount with an explicit amount.",
        claimed_account_ids: claimed_ids,
        available_accounts: available_payload
      )
    end

    allocations = specs.to_h do |spec|
      allocation = spec.fetch(:allocation)
      amount = allocation[:mode] == "fixed_amount" ? allocation.fetch(:amount) : nil
      [ spec.fetch(:account_id), amount ]
    end

    Selection.new(accounts:, allocations:)
  end

  def available_payload
    accounts = accessible_accounts.to_a
    availability = Goal::FundingAvailability.for(family:, accounts:, excluding_goal: goal)

    accounts.map do |account|
      funding = availability.fetch(account.id.to_s)
      {
        id: account.id,
        name: account.name,
        currency: account.currency,
        goal_funding: {
          status: funding.status,
          free_to_earmark: funding.free_to_earmark
        }
      }
    end
  end

  private
    attr_reader :user, :family, :raw, :goal

    def accessible_accounts
      self.class.fundable_accounts_for(user)
    end

    def parse_specs
      items = Array(raw)
      raise Invalid.new("no_funding_accounts", "Provide at least one funding account.", available_accounts: available_payload) if items.empty?

      specs = items.map { |item| parse_spec(item) }
      ids = specs.map { |spec| spec[:account_id] }
      raise Invalid.new("duplicate_funding_account", "Each funding account may appear only once.") unless ids.uniq.size == ids.size

      specs
    end

    def parse_spec(item)
      raise Invalid.new("invalid_funding_account", "Each funding account must be an object.") unless item.is_a?(Hash)

      account_id = item["account_id"].to_s
      raise Invalid.new("invalid_funding_account", "account_id must be a UUID.") unless UuidFormat.valid?(account_id)

      allocation = item["allocation"]
      raise Invalid.new("invalid_allocation", "allocation must be an object.") unless allocation.is_a?(Hash)

      mode = allocation["mode"].to_s
      raise Invalid.new("invalid_allocation", "allocation.mode must be one of: #{MODES.join(', ')}.") unless MODES.include?(mode)

      amount_present = allocation.key?("amount")
      amount = parse_amount(allocation["amount"]) if amount_present
      if mode == "fixed_amount"
        raise Invalid.new("invalid_allocation", "fixed_amount requires a finite amount greater than zero.") unless amount&.positive? && amount.finite?
      elsif amount_present
        raise Invalid.new("invalid_allocation", "whole_account must not include an amount.")
      end

      { account_id:, allocation: { mode:, amount: } }
    end

    def parse_amount(value)
      BigDecimal(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end
end
