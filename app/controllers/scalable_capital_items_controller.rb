class ScalableCapitalItemsController < ApplicationController
  before_action :require_admin
  before_action :require_configured, only: %i[discover create sync]
  before_action :require_preview_features!, only: %i[discover create]
  before_action :set_item, only: %i[sync destroy]

  def discover
    @discovery = ScalableCapitalItem::Discovery.new.fetch
  rescue Provider::ScalableCapital::AuthenticationError
    redirect_to bank_sync_path, alert: t(".sign_in"), status: :see_other
  rescue Provider::ScalableCapital::Error
    redirect_to bank_sync_path, alert: t(".unavailable"), status: :see_other
  end

  def create
    input = params[:scalable_capital_item]
    tokens = input[:choices] if input.is_a?(ActionController::Parameters)
    selections = verified_selections(tokens)
    return redirect_to bank_sync_path, alert: t(".invalid") unless selections

    item = Current.family.scalable_capital_items.create!(
      owner: Current.user,
      broker_account_id: selections.first.fetch("identity"),
      selected_sources: selections.map { |selection| selection.except("identity") }
    )
    item.sync_later
    redirect_to bank_sync_path, notice: t(".started")
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
    redirect_to bank_sync_path, alert: t(".invalid")
  end

  def sync
    @item.sync_later
    redirect_back fallback_location: bank_sync_path, notice: t(".started")
  end

  def destroy
    @item.with_lock { @item.destroy! }
    redirect_to bank_sync_path, notice: t(".disconnected"), status: :see_other
  end

  private

    helper_method :selection_token

    def selection_token(choice)
      selection_verifier.generate(choice.to_h.merge(identity: @discovery.identity).stringify_keys,
                                  expires_in: 10.minutes, purpose: selection_purpose)
    end

    def verified_selections(tokens)
      return unless tokens.is_a?(Array) && tokens.size.between?(1, 50) && tokens.all? { |token| token.is_a?(String) }

      selections = tokens.uniq.map { |token| selection_verifier.verified(token, purpose: selection_purpose) }
      return if selections.any?(&:nil?) || selections.pluck("identity").uniq.size != 1

      selections.uniq { |selection| selection.values_at("kind", "id") }
    end

    def selection_verifier
      Rails.application.message_verifier(:scalable_capital_account_selection)
    end

    def selection_purpose
      [ Current.family.id, Current.user.id ].join(":")
    end

    def require_admin
      return if Current.user.admin?

      redirect_to root_path, alert: t("settings.providers.not_authorized")
    end

    def require_configured
      return if ScalableCapitalItem.configured_family_id == Current.family.id

      redirect_to bank_sync_path, alert: t("scalable_capital_items.disabled")
    end

    def set_item
      @item = Current.family.scalable_capital_items.find(params[:id])
    end

    def bank_sync_path
      settings_providers_path(anchor: "scalable-capital-connection")
    end
end
