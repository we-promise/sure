# frozen_string_literal: true

# PluggyItem::AutoSetup — first-sync auto-account-creation.
#
# On the very first successful sync of a freshly-connected PluggyItem, this PORO
# creates a real Account (with an inferred accountable type) for every
# unlinked PluggyAccount and wires the polymorphic AccountProvider link — the
# same outcome the user would otherwise drive through the manual "Set up your
# Pluggy accounts" wizard (PluggyItemsController#complete_account_setup).
#
# Trigger (migration-free, evaluated by the Syncer's Phase 2.5 caller): the item
# has not completed initial setup yet (PluggyItem#has_completed_initial_setup? —
# i.e. no PluggyAccount is linked to an Account). Once anything is linked — by
# this PORO or by the user manually — every subsequent sync skips auto-setup, so
# new bank accounts the provider reports later fall through to the wizard for
# human review (the safer default for a finance app).
#
# Notes:
# - Reuses PluggyAccount#suggested_setup_account_type (the wizard's own type
#   detector) so auto-created accounts classify exactly the way the wizard
#   would, then maps the bucket string to an accountable class.
# - Uses pluggy_item.family (not Current.family) — this runs in a syncer/job
#   context with no controller auth.
# - Idempotent: skips any PluggyAccount that already has an AccountProvider.
# - Per-account rescue (warn-and-continue) mirrors the existing pattern at
#   simplefin_account/processor.rb for ensure_account_provider! failures, so a
#   single bad row cannot abort the parent sync.
class PluggyItem::AutoSetup
  # Map the wizard-type buckets returned by PluggyAccount#suggested_setup_account_type
  # to the accountable class *names* Account#delegated_type accepts (mirrors the
  # ALLOWED_ACCOUNTABLE_TYPES cast PluggyItemsController#infer_accountable_type
  # performs). Stored as strings and constantized at call time — matching the
  # controller's lazy lookup — so requiring this file does not eager-load the
  # accountable classes at boot. Default fallback is Depository.
  ACCOUNTABLE_CLASS_NAMES = {
    "depository"  => "Depository",
    "credit_card" => "CreditCard",
    "loan"        => "Loan",
    "investment"  => "Investment",
    "other_asset" => "OtherAsset"
  }.freeze

  def initialize(pluggy_item)
    @pluggy_item = pluggy_item
  end

  def call
    pluggy_item.unlinked_pluggy_accounts.each do |pluggy_account|
      begin
        create_account_for(pluggy_account)
      rescue => e
        Rails.logger.warn(
          "PluggyItem::AutoSetup - failed for pluggy_account #{pluggy_account.id} on item #{pluggy_item.id}: #{e.class} - #{e.message}"
        )
      end
    end
  end

  private
    attr_reader :pluggy_item

    def create_account_for(pluggy_account)
      return if pluggy_account.account_provider.present?

      accountable_name = ACCOUNTABLE_CLASS_NAMES.fetch(pluggy_account.suggested_setup_account_type, "Depository")
      # Pluggy reports CreditCard/Loan balances as positive numbers; Sure stores
      # liabilities as negative (see PluggyAccount::Processor#upsert_balance). Mirror
      # that here so an auto-created card/loan doesn't show up as a positive asset.
      balance = pluggy_account.current_balance || 0
      balance = -balance if accountable_name.in?(%w[CreditCard Loan])
      account = pluggy_item.family.accounts.create!(
        name: pluggy_account.name,
        balance: balance,
        currency: pluggy_account.currency || "USD",
        accountable: accountable_name.constantize.new
      )
      pluggy_account.ensure_account_provider!(account)
    end
end
