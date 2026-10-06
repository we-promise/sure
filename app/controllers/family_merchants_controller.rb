class FamilyMerchantsController < ApplicationController
  before_action :set_merchant, only: %i[edit update destroy]
  before_action :set_entry_for_picker_options, only: :picker_options
  before_action :set_entry_for_merchant_creation, only: %i[new create]

  def picker_options
    merchants = Current.family.available_merchants_for(Current.user).alphabetically.to_a
    render json: {
      html: render_to_string(
        partial: "DS/merchant_select/options",
        formats: [ :html ],
        locals: {
          merchants: merchants,
          selected_id: params[:selected_id].to_s,
          include_blank: t("transactions.form.none"),
          view_helpers: helpers,
          avatar: true,
          fallback_text: @entry.name,
          avatar_size: %w[sm md lg].include?(params[:avatar_size]) ? params[:avatar_size].to_sym : :sm
        }
      )
    }
  end

  def index
    @breadcrumbs = [ [ t("breadcrumbs.home"), root_path ], [ t("breadcrumbs.merchants"), nil ] ]

    # There is one family-scoped merchant collection, including records first
    # discovered through a provider sync.
    @all_family_merchants = Current.family.merchants.alphabetically

    family_scope = @all_family_merchants
    search = params[:family_search].presence || params[:provider_search]
    if search.is_a?(String) && search.strip.present?
      family_scope = family_scope.where("LOWER(name) LIKE ?", "%#{ActiveRecord::Base.sanitize_sql_like(search.strip.downcase)}%")
    end

    @enhanceable_count = @all_family_merchants.where(website_url: [ nil, "" ]).count
    @llm_available = Provider::Registry.get_provider(:openai).present?

    @pagy_family_merchants, @family_merchants = pagy(family_scope, page_param: :family_page, limit: safe_per_page)

    render layout: "settings"
  end

  def new
    @family_merchant = FamilyMerchant.new(family: Current.family, name: params[:name])
    render layout: false if turbo_frame_request?
  end

  def create
    @family_merchant = FamilyMerchant.new(merchant_params.merge(family: Current.family))

    if @family_merchant.save
      assign_created_merchant_to_entry if @entry

      respond_to do |format|
        format.html { redirect_to family_merchants_path, notice: t(".success") }
        format.turbo_stream do
          if @entry
            render turbo_stream: merchant_assignment_streams
          else
            render turbo_stream: turbo_stream.action(:redirect, family_merchants_path)
          end
        end
        format.json { render json: merchant_json(@family_merchant), status: :created }
      end
    else
      respond_to do |format|
        # Preserve the dialog in its modal frame on validation errors for both HTML
        # frame submissions and Turbo Stream form submissions.
        format.html { render :new, status: :unprocessable_entity, layout: turbo_frame_request? ? false : nil }
        format.turbo_stream do
          dialog = render_to_string(:new, formats: [ :html ], layout: false)
          render turbo_stream: turbo_stream.replace("modal", dialog), status: :unprocessable_entity
        end
        format.json { render json: { errors: @family_merchant.errors.full_messages }, status: :unprocessable_entity }
      end
    end
  end

  def edit
  end

  def update
    attributes = merchant_params
    remove_logo_image = ActiveModel::Type::Boolean.new.cast(attributes.delete(:remove_logo_image))

    if @merchant.update(attributes)
      @merchant.logo_image.purge_later if remove_logo_image && @merchant.logo_image.attached?

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
    @merchant.destroy!
    redirect_to family_merchants_path, notice: t(".success")
  end

  def enhance
    cache_key = "enhance_family_merchants:#{Current.family.id}"

    already_running = !Rails.cache.write(cache_key, true, expires_in: 10.minutes, unless_exist: true)

    if already_running
      return redirect_to family_merchants_path, alert: t(".already_running")
    end

    EnhanceFamilyMerchantsJob.perform_later(Current.family)
    redirect_to family_merchants_path, notice: t(".success")
  end

  def merge
    @merchants = all_family_merchants
  end

  def perform_merge
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
    def set_entry_for_picker_options
      @entry = Current.accessible_entries
        .where(entryable_type: "Transaction")
        .find(params[:entry_id])
      require_account_permission!(@entry.account, :annotate)
    end

    def set_entry_for_merchant_creation
      return if params[:entry_id].blank?

      @entry = Current.accessible_entries
        .where(entryable_type: "Transaction")
        .find(params[:entry_id])
      require_account_permission!(@entry.account, :annotate)
    end

    def assign_created_merchant_to_entry
      transaction = @entry.transaction
      transaction.update!(merchant: @family_merchant)
      @entry.lock_saved_attributes!
      @entry.mark_user_modified!
      transaction.lock_attr!(:merchant_id)
      @entry.sync_account_later
    end

    def merchant_assignment_streams
      transaction = @entry.transaction
      streams = %i[desktop mobile].map do |variant|
        turbo_stream.replace(
          helpers.dom_id(transaction, "merchant_picker_#{variant}"),
          partial: "transactions/merchant_picker",
          locals: { entry: @entry, variant: variant }
        )
      end
      streams << turbo_stream.replace("modal", helpers.turbo_frame_tag("modal"))
      streams
    end

    def set_merchant
      @merchant = Current.family.merchants.find(params[:id])
      @family_merchant = @merchant # For backwards compatibility with views
    end

    def merchant_params
      params.require(:family_merchant).permit(:name, :color, :website_url, :custom_logo_url, :logo_image, :remove_logo_image)
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
      Current.family.merchants.order(Arel.sql("LOWER(COALESCE(name, ''))"))
    end
end
