class Financekit::AccountMapping
  TYPES = { "Depository" => Depository, "CreditCard" => CreditCard }.freeze

  def initialize(item, source_id, input)
    @item = item
    @source_id = source_id
    @input = input
  end

  def apply!
    validate!
    @item.family.with_lock do
      @item.lock!
      Financekit.require!(%w[pending_mapping repair_required].include?(@item.status), "mapping_closed", 409)
      Financekit.require!(@item.consented_source_ids.any? { |id| id.casecmp?(@source_id) },
        "account_not_consented", 403)
      existing = @item.financekit_accounts.find_by(source_id: @source_id)
      return replay!(existing) if existing

      Financekit.require!(@input["expected_version"] == 0, "mapping_conflict", 409)
      account, lineage = resolve_account_and_lineage!
      validate_canonical!(account)
      version = lineage.financekit_accounts.maximum(:mapping_version).to_i + 1
      @item.financekit_accounts.create!(financekit_account_lineage: lineage, source_id: @source_id,
        mapping_version: version, mapping_digest: mapping_digest,
        name: @input["name"], institution_name: @input["institution_name"], currency: @input["currency"],
        accountable_type: @input["accountable_type"], subtype: @input["subtype"],
        ledger_timezone: @input["ledger_timezone"])
    end
  rescue Money::Currency::UnknownCurrencyError
    raise Financekit::Error.new("invalid_currency")
  end

  private

    def validate!
      Financekit::Payload.uuid!(@source_id)
      Financekit::Payload.shape!(@input,
        %w[expected_version action name institution_name currency accountable_type subtype ledger_timezone],
        %w[account_id lineage_id booked_balance observed_at])
      Financekit::Payload.text!(@input["name"])
      Financekit::Payload.text!(@input["institution_name"])
      Financekit.require!(%w[create link].include?(@input["action"]))
      type = TYPES[@input["accountable_type"]]
      Financekit.require!(type && type::SUBTYPES.key?(@input["subtype"]), "confirmed_subtype_required")
      Financekit.require!(Money::Currency.new(@input["currency"]).iso_code == @input["currency"])
      Financekit.require!(TZInfo::Timezone.all_identifiers.include?(@input["ledger_timezone"]), "invalid_timezone")
      Financekit.require!(@input["expected_version"].is_a?(Integer))
    end

    def replay!(existing)
      Financekit.require!(existing.mapping_digest == mapping_digest &&
        [ existing.mapping_version, existing.mapping_version - 1 ].include?(@input["expected_version"]),
        "mapping_conflict", 409)
      existing
    end

    def resolve_account_and_lineage!
      return link_account_and_lineage! if @input["action"] == "link"

      Financekit.require!(!@input.key?("account_id"))
      prior = FinancekitAccount.joins(:financekit_item)
        .where(source_id: @source_id, financekit_items: { family_id: @item.family_id, user_id: @item.user_id })
        .includes(financekit_account_lineage: :account).order(created_at: :desc).first
      return [ prior.account, prior.financekit_account_lineage ] if prior&.account

      Financekit::Payload.money!(@input.fetch("booked_balance"))
      Financekit.require!(@input["booked_balance"]["currency"] == @input["currency"], "currency_mismatch")
      Financekit.require!(Financekit::Payload.timestamp!(@input.fetch("observed_at")) <= Time.current + 5.minutes)
      type = TYPES.fetch(@input["accountable_type"])
      account = @item.family.accounts.create!(owner: @item.user, name: @input["name"], currency: @input["currency"],
        balance: Financekit::Mapping.balance(@input["booked_balance"], @input["accountable_type"]),
        accountable: type.new(subtype: @input["subtype"]), status: "active")
      [ account, @item.family.financekit_account_lineages.create!(account: account) ]
    end

    def link_account_and_lineage!
      Financekit.require!(!@input.key?("booked_balance") && !@input.key?("observed_at"))
      account = @item.family.accounts.writable_by(@item.user).find(@input.fetch("account_id"))
      lineage = if @input["lineage_id"]
        @item.family.financekit_account_lineages.find(@input["lineage_id"])
      else
        @item.family.financekit_account_lineages.find_by(account: account)
      end
      Financekit.require!(!lineage || lineage.account_id == account.id, "lineage_account_conflict", 409)
      lineage ||= @item.family.financekit_account_lineages.create!(account: account)
      [ account, lineage ]
    end

    def validate_canonical!(account)
      Financekit.require!(account.currency == @input["currency"] && account.accountable_type == @input["accountable_type"] &&
        account.accountable.subtype == @input["subtype"], "account_type_conflict", 409)
      provider = account.account_providers.first
      current_lineage = @item.family.financekit_account_lineages.find_by(account: account)
      Financekit.require!(!provider || provider.provider == current_lineage, "account_already_supplied", 409)
    end

    def mapping_digest
      @mapping_digest ||= Digest::SHA256.hexdigest(
        Financekit::Enrollment.canonical(@input.except("expected_version")))
    end
end
