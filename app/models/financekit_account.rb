class FinancekitAccount < ApplicationRecord
  belongs_to :financekit_item
  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :account, through: :account_provider
  has_many :financekit_transactions, dependent: :destroy

  def self.map!(item, source_id, input)
    Financekit::Payload.uuid!(source_id)
    Financekit::Payload.shape!(input, %w[expected_version action name currency accountable_type subtype ledger_timezone], %w[account_id booked_balance observed_at])
    Financekit::Payload.text!(input["name"])
    Financekit.require!(%w[create link].include?(input["action"]))
    types = { "Depository" => Depository, "CreditCard" => CreditCard }
    type = types[input["accountable_type"]]
    Financekit.require!(type && type::SUBTYPES.key?(input["subtype"]), "confirmed_subtype_required")
    Financekit.require!(input["currency"].is_a?(String) && Money::Currency.new(input["currency"]).iso_code == input["currency"])
    Financekit.require!(TZInfo::Timezone.all_identifiers.include?(input["ledger_timezone"]), "invalid_timezone")
    item.with_lock do
      Financekit.require!(input["expected_version"].is_a?(Integer))
      Financekit.require!(item.consent.fetch("source_ids").include?(source_id), "account_not_consented", 403)
      Financekit.require!(item.status == "active", "connection_revoked", 403)
      existing = item.financekit_accounts.find_by(source_id: source_id)
      if existing
        digest = Digest::SHA256.hexdigest(Financekit::Enrollment.canonical(input.except("expected_version")))
        Financekit.require!(existing.mapping_digest == digest && [ existing.mapping_version, existing.mapping_version - 1 ].include?(input["expected_version"]), "mapping_conflict", 409)
        return existing
      end
      Financekit.require!(input["expected_version"] == 0, "mapping_conflict", 409)
      canonical = if input["action"] == "link"
        item.family.accounts.writable_by(item.user).find(input.fetch("account_id"))
      else
        Financekit.require!(!input.key?("account_id"))
        Financekit::Payload.money!(input.fetch("booked_balance"))
        Financekit.require!(input["booked_balance"]["currency"] == input["currency"], "currency_mismatch")
        Financekit.require!(Financekit::Payload.timestamp!(input.fetch("observed_at")) <= Time.current + 5.minutes)
        item.family.accounts.create!(owner: item.user, name: input["name"], currency: input["currency"],
          balance: Financekit::Mapping.balance(input["booked_balance"], input["accountable_type"]),
          accountable: type.new(subtype: input["subtype"]), status: "active")
      end
      canonical.with_lock do
        Financekit.require!(canonical.currency == input["currency"] && canonical.accountable_type == input["accountable_type"] &&
          canonical.accountable.subtype == input["subtype"], "account_type_conflict", 409)
        Financekit.require!(!canonical.account_providers.exists?, "account_already_supplied", 409)
        # Another publisher is not allowed to share this canonical account.
        source = item.financekit_accounts.create!(input.slice("name", "currency", "accountable_type", "subtype", "ledger_timezone").merge("source_id" => source_id,
          "mapping_digest" => Digest::SHA256.hexdigest(Financekit::Enrollment.canonical(input.except("expected_version")))))
        canonical.account_providers.create!(provider: source)
        source
      end
    end
  rescue Money::Currency::UnknownCurrencyError
    raise Financekit::Error.new("invalid_currency")
  end

  def raw_payload
    nil
  end
end
