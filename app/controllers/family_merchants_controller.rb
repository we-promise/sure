class FamilyMerchantsController < ApplicationController
  InvalidMerchantWebsite = Class.new(StandardError)
  MergeTargetNotFound = Class.new(StandardError)
  EmptyMerchantMerge = Class.new(StandardError)

  before_action :set_merchant, only: %i[edit update destroy]

  def index
    @breadcrumbs = [ [ "Home", root_path ], [ "Merchants", nil ] ]

    # Show all merchants for this family
    @family_merchants = Current.family.merchants.alphabetically
    @provider_merchants = Current.family.assigned_merchants_for(Current.user).where(type: "ProviderMerchant").alphabetically

    # Show recently unlinked ProviderMerchants (within last 30 days)
    # Exclude merchants that are already assigned to transactions (they appear in provider_merchants)
    recently_unlinked_ids = FamilyMerchantAssociation
      .where(family: Current.family)
      .recently_unlinked
      .pluck(:merchant_id)
    assigned_ids = @provider_merchants.pluck(:id)
    @unlinked_merchants = ProviderMerchant.where(id: recently_unlinked_ids - assigned_ids).alphabetically

    @enhanceable_count = @provider_merchants.where(website_url: [ nil, "" ]).count
    @llm_available = Provider::Registry.get_provider(:openai).present?

    render layout: "settings"
  end

  def new
    @family_merchant = FamilyMerchant.new(family: Current.family)
  end

  def create
    @family_merchant = FamilyMerchant.new(merchant_params.merge(family: Current.family))

    if @family_merchant.save
      respond_to do |format|
        format.html { redirect_to family_merchants_path, notice: t(".success") }
        format.turbo_stream { render turbo_stream: turbo_stream.action(:redirect, family_merchants_path) }
      end
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @merchant.is_a?(ProviderMerchant)
      if merchant_params[:name].present? && merchant_params[:name] != @merchant.name
        # Name changed — convert ProviderMerchant to FamilyMerchant for this family only
        @family_merchant = @merchant.convert_to_family_merchant_for(Current.family, merchant_params)
        respond_to do |format|
          format.html { redirect_to family_merchants_path, notice: t(".converted_success") }
          format.turbo_stream { render turbo_stream: turbo_stream.action(:redirect, family_merchants_path) }
        end
      else
        # Only website changed — update the ProviderMerchant directly
        @merchant.update!(merchant_params.slice(:website_url))
        @merchant.generate_logo_url_from_website!
        respond_to do |format|
          format.html { redirect_to family_merchants_path, notice: t(".success") }
          format.turbo_stream { render turbo_stream: turbo_stream.action(:redirect, family_merchants_path) }
        end
      end
    elsif @merchant.update(merchant_params)
      respond_to do |format|
        format.html { redirect_to family_merchants_path, notice: t(".success") }
        format.turbo_stream { render turbo_stream: turbo_stream.action(:redirect, family_merchants_path) }
      end
    else
      render :edit, status: :unprocessable_entity
    end
  rescue ActiveRecord::RecordInvalid => e
    @family_merchant = e.record
    render :edit, status: :unprocessable_entity
  end

  def destroy
    if @merchant.is_a?(ProviderMerchant)
      # Unlink from family's transactions only (don't delete the global merchant)
      @merchant.unlink_from_family(Current.family)
      redirect_to family_merchants_path, notice: t(".unlinked_success")
    else
      @merchant.destroy!
      redirect_to family_merchants_path, notice: t(".success")
    end
  end

  def enhance
    cache_key = "enhance_provider_merchants:#{Current.family.id}"

    already_running = !Rails.cache.write(cache_key, true, expires_in: 10.minutes, unless_exist: true)

    if already_running
      return redirect_to family_merchants_path, alert: t(".already_running")
    end

    EnhanceProviderMerchantsJob.perform_later(Current.family)
    redirect_to family_merchants_path, notice: t(".success")
  end

  def merge
    @merchants = all_family_merchants
    @default_merchant_color = FamilyMerchant.default_color

    render layout: "settings"
  end

  def bulk_websites
    @merchants = all_family_merchants
  end

  def bulk_update_websites
    permitted_params = bulk_website_params
    merchants = all_family_merchants.where(id: permitted_params[:merchant_ids])
    website_url = Merchant.extract_domain(permitted_params[:website_url])

    unless merchants.any? && website_url.present?
      return redirect_to bulk_websites_family_merchants_path, alert: t(".invalid_selection")
    end

    Merchant.transaction do
      merchants.each do |merchant|
        merchant.update!(website_url: website_url)
        merchant.generate_logo_url_from_website! if merchant.is_a?(ProviderMerchant)
      end
    end

    redirect_to family_merchants_path, notice: t(".success", count: merchants.count)
  rescue ActiveRecord::RecordInvalid => e
    error_message = e.record.errors.full_messages.to_sentence.presence || e.message
    redirect_to bulk_websites_family_merchants_path, alert: t(".failure", error: error_message)
  end

  def perform_merge
    permitted_params = merchant_merge_params

    if conflicting_merge_target?(permitted_params)
      return redirect_to merge_family_merchants_path, alert: t(".conflicting_target")
    end

    # Scope lookups to merchants valid for this family (FamilyMerchants + assigned ProviderMerchants)
    valid_merchants = all_family_merchants

    sources = valid_merchants.where(id: permitted_params[:source_ids])
    unless sources.any?
      return redirect_to merge_family_merchants_path, alert: t(".invalid_merchants")
    end

    merger = merge_merchants!(valid_merchants, permitted_params, sources)

    redirect_to family_merchants_path, notice: t(".success", count: merger.merged_count)
  rescue MergeTargetNotFound
    redirect_to merge_family_merchants_path, alert: t(".target_not_found")
  rescue EmptyMerchantMerge
    redirect_to merge_family_merchants_path, alert: t(".no_merchants_selected")
  rescue Merchant::Merger::UnauthorizedMerchantError => e
    redirect_to merge_family_merchants_path, alert: e.message
  rescue InvalidMerchantWebsite
    redirect_to merge_family_merchants_path, alert: t(".invalid_website")
  rescue ActiveRecord::RecordInvalid => e
    redirect_to merge_family_merchants_path, alert: record_error_message(e)
  end

  private
    def set_merchant
      # Find merchant that either belongs to family OR is assigned to family's transactions
      @merchant = Current.family.merchants.find_by(id: params[:id]) ||
                  Current.family.assigned_merchants.find(params[:id])
      @family_merchant = @merchant # For backwards compatibility with views
    end

    def merchant_params
      # Handle both family_merchant and provider_merchant param keys
      key = params.key?(:family_merchant) ? :family_merchant : :provider_merchant
      params.require(key).permit(:name, :color, :website_url)
    end

    def bulk_website_params
      params.permit(:website_url, merchant_ids: [])
    end

    def merchant_merge_params
      params.permit(:target_id, :new_target_name, :new_target_color, :new_target_website_url, source_ids: [])
    end

    def conflicting_merge_target?(permitted_params)
      permitted_params[:target_id].present? && permitted_params[:new_target_name].present?
    end

    def all_family_merchants
      family_merchant_ids = Current.family.merchants.pluck(:id)
      provider_merchant_ids = Current.family.assigned_merchants.where(type: "ProviderMerchant").pluck(:id)
      combined_ids = (family_merchant_ids + provider_merchant_ids).uniq

      Merchant.where(id: combined_ids)
              .order(Arel.sql("LOWER(COALESCE(name, ''))"))
    end

    def merge_target_merchant(valid_merchants, permitted_params)
      if permitted_params[:new_target_name].present?
        website_url = normalized_new_target_website_url(permitted_params)

        Current.family.merchants.create!(
          name: permitted_params[:new_target_name],
          color: permitted_params[:new_target_color].presence || FamilyMerchant.default_color,
          website_url: website_url
        )
      else
        valid_merchants.find_by(id: permitted_params[:target_id])
      end
    end

    def normalized_new_target_website_url(permitted_params)
      return if permitted_params[:new_target_website_url].blank?

      Merchant.extract_domain(permitted_params[:new_target_website_url]).presence || raise(InvalidMerchantWebsite)
    end

    def merge_merchants!(valid_merchants, permitted_params, sources)
      Merchant.transaction do
        target = merge_target_merchant(valid_merchants, permitted_params) || raise(MergeTargetNotFound)
        merger = Merchant::Merger.new(
          family: Current.family,
          target_merchant: target,
          source_merchants: sources
        )

        raise EmptyMerchantMerge unless merger.merge!

        merger
      end
    end

    def record_error_message(error)
      record = error.respond_to?(:record) ? error.record : nil
      record&.errors&.full_messages&.to_sentence.presence || error.message
    end
end
