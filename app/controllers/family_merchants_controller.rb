class FamilyMerchantsController < ApplicationController
  before_action :require_non_guest!, except: %i[index]
  before_action :set_merchant, only: %i[edit update destroy]
  before_action :store_params!, only: :index

  LIST_PARAMS = %w[family_search family_page provider_search provider_page per_page].freeze
  NUMERIC_LIST_PARAMS = %w[family_page provider_page per_page].freeze

  def index
    @breadcrumbs = [ [ t("breadcrumbs.home"), root_path ], [ t("breadcrumbs.merchants"), nil ] ]

    # Show all merchants for this family
    @all_family_merchants = Current.family.merchants.alphabetically
    @all_provider_merchants = Current.family.assigned_merchants_for(Current.user).where(type: "ProviderMerchant").alphabetically

    family_scope = @all_family_merchants
    if params[:family_search].is_a?(String) && params[:family_search].strip.present?
      family_scope = family_scope.where("LOWER(name) LIKE ?", "%#{ActiveRecord::Base.sanitize_sql_like(params[:family_search].strip.downcase)}%")
    end

    provider_scope = @all_provider_merchants
    if params[:provider_search].is_a?(String) && params[:provider_search].strip.present?
      provider_scope = provider_scope.where("LOWER(name) LIKE ?", "%#{ActiveRecord::Base.sanitize_sql_like(params[:provider_search].strip.downcase)}%")
    end

    # Show recently unlinked ProviderMerchants (within last 30 days)
    # Exclude merchants that are already assigned to transactions (they appear in provider_merchants)
    recently_unlinked_ids = FamilyMerchantAssociation
      .where(family: Current.family)
      .recently_unlinked
      .pluck(:merchant_id)
    assigned_ids = @all_provider_merchants.pluck(:id)
    @unlinked_merchants = ProviderMerchant.where(id: recently_unlinked_ids - assigned_ids).alphabetically

    @enhanceable_count = @all_provider_merchants.where(website_url: [ nil, "" ]).count
    @llm_available = Provider::Registry.get_provider(:openai).present?

    @pagy_family_merchants, @family_merchants = pagy(family_scope.with_attached_logo, page_param: :family_page, limit: safe_per_page)
    @pagy_provider_merchants, @provider_merchants = pagy(provider_scope, page_param: :provider_page, limit: safe_per_page)

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
        format.json { render json: merchant_json(@family_merchant), status: :created }
      end
    else
      respond_to do |format|
        # No explicit format.turbo_stream branch: Turbo's form submissions send an
        # Accept header that prefers turbo-stream, but forcing that format here would
        # lock the response's Content-Type to turbo-stream while still rendering the
        # plain :new HTML template — Turbo's client then sees a turbo-stream
        # Content-Type with no <turbo-stream> tags in the body and does nothing.
        # Leaving turbo-stream undeclared lets Rails' content negotiation fall back to
        # format.html below, which renders :new with the correct text/html type.
        format.html { render :new, status: :unprocessable_entity }
        format.json { render json: { errors: @family_merchant.errors.full_messages }, status: :unprocessable_entity }
      end
    end
  end

  def edit
  end

  def update
    if @merchant.is_a?(ProviderMerchant)
      # A ProviderMerchant is shared by every family whose transactions use it,
      # so changing its name or website converts it to a FamilyMerchant for this
      # family only; editing the shared row would change it for all of them.
      if provider_merchant_customized?
        @family_merchant = @merchant.convert_to_family_merchant_for(Current.family, merchant_params)
        respond_to do |format|
          format.html { redirect_to family_merchants_path, notice: t(".converted_success") }
          format.turbo_stream { render turbo_stream: turbo_stream.action(:redirect, family_merchants_path) }
        end
      else
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
    cache_key = EnhanceProviderMerchantsJob.lock_key(Current.family)

    already_running = !Rails.cache.write(cache_key, true, expires_in: EnhanceProviderMerchantsJob::LOCK_TTL, unless_exist: true)

    if already_running
      return redirect_to family_merchants_path, alert: t(".already_running")
    end

    EnhanceProviderMerchantsJob.perform_later(Current.family)
    redirect_to family_merchants_path, notice: t(".success")
  end

  def merge
    @merchants = all_family_merchants.with_attached_logo
  end

  def perform_merge
    # Scope lookups to merchants valid for this family (FamilyMerchants + assigned ProviderMerchants)
    valid_merchants = all_family_merchants

    target = valid_merchants.find_by(id: params[:target_id])
    unless target
      return redirect_to merge_family_merchants_path, alert: t(".target_not_found")
    end

    sources = valid_merchants.where(id: params[:source_ids])
    unless sources.any?
      return redirect_to merge_family_merchants_path, alert: t(".invalid_merchants")
    end

    merger = Merchant::Merger.new(
      family: Current.family,
      target_merchant: target,
      source_merchants: sources
    )

    if merger.merge!
      redirect_to family_merchants_path, notice: t(".success", count: merger.merged_count)
    else
      redirect_to merge_family_merchants_path, alert: t(".no_merchants_selected")
    end
  rescue Merchant::Merger::UnauthorizedMerchantError => e
    redirect_to merge_family_merchants_path, alert: e.message
  end

  private
    # Like TransactionsController#store_params!: remembers the list state per
    # session, so redirects back to the bare index (after edit, delete, merge,
    # ...) keep the chosen page size, page and search.
    def store_params!
      # Only requests carrying list params (query or JSON body) change the stored state.
      if (params.keys & LIST_PARAMS).empty?
        redirect_to family_merchants_path(stored_params) if request.query_parameters.blank? && stored_params.present?
      else
        list_params = params.slice(*LIST_PARAMS).permit(*LIST_PARAMS).to_h.compact_blank
          .to_h { |key, value| [ key, normalize_list_param(key, value.to_s) ] }.compact
        Current.session.set_merchant_page_params(list_params) unless list_params == stored_params
      end
    end

    # Values are stored as strings, so a JSON number and the same query value
    # compare equal. A page Pagy rejects (0, "abc") is dropped so it is not
    # replayed on every later visit; "05" is kept as "5", as Pagy reads it.
    def normalize_list_param(key, value)
      return value unless NUMERIC_LIST_PARAMS.include?(key)

      value.to_i.to_s if value.match?(/\A\d+\z/) && value.to_i.positive?
    end

    def stored_params
      Current.session.merchant_page_params
    end

    def set_merchant
      # Find merchant that either belongs to family OR is assigned to family's transactions
      @merchant = Current.family.merchants.find_by(id: params[:id]) ||
                  Current.family.assigned_merchants.find(params[:id])
      @family_merchant = @merchant # For backwards compatibility with views
    end

    def provider_merchant_customized?
      name_changed = merchant_params[:name].present? && merchant_params[:name] != @merchant.name
      website_changed = merchant_params.key?(:website_url) &&
        merchant_params[:website_url].to_s.strip != @merchant.website_url.to_s

      name_changed || website_changed
    end

    def merchant_params
      # Handle both family_merchant and provider_merchant param keys
      key = params.key?(:family_merchant) ? :family_merchant : :provider_merchant
      params.require(key).permit(:name, :color, :website_url, :logo, :remove_logo)
    end

    def merchant_json(merchant)
      merchant.as_json(only: %i[id name]).merge(
        html: render_to_string(
          partial: "DS/merchant_select/option",
          formats: [ :html ],
          locals: { merchant: merchant, selected: true, view_helpers: helpers }
        )
      )
    end

    def all_family_merchants
      family_merchant_ids = Current.family.merchants.pluck(:id)
      provider_merchant_ids = Current.family.assigned_merchants.where(type: "ProviderMerchant").pluck(:id)
      combined_ids = (family_merchant_ids + provider_merchant_ids).uniq

      Merchant.where(id: combined_ids)
              .order(Arel.sql("LOWER(COALESCE(name, ''))"))
    end
end
