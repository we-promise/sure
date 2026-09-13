class FamilyMerchantsController < ApplicationController
  before_action :set_merchant, only: %i[edit update destroy]

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

    @pagy_family_merchants, @family_merchants = pagy(family_scope, page_param: :family_page, limit: safe_per_page)
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
      render_create_error
    end
  rescue ActiveRecord::RecordNotUnique
    # A raw DB-level race on the partial (family_id, iban) unique index: two
    # concurrent creates both passed the Rails uniqueness validation before
    # either committed, so it surfaces here instead of the `save` branch
    # above. #save doesn't rescue this on its own since it's a raw
    # PG::UniqueViolation, not a validation failure.
    @family_merchant.errors.add(:iban, :taken)
    render_create_error
  end

  def edit
  end

  def update
    if @merchant.is_a?(ProviderMerchant)
      name_changed = merchant_params[:name].present? && merchant_params[:name] != @merchant.name
      # An IBAN edit must not mutate the shared ProviderMerchant row: unlike
      # website_url (cosmetic, logo lookup only), iban drives cross-family
      # merchant-identity matching (Account::ProviderImportAdapter looks
      # merchants up globally by source+iban), so one family setting it would
      # silently redirect another family's future transactions to this
      # merchant. Route it through the same conversion path as a name change.
      iban_changed = merchant_params.key?(:iban) && normalize_iban(merchant_params[:iban]) != @merchant.iban

      if name_changed || iban_changed
        # Convert ProviderMerchant to FamilyMerchant for this family only
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
    # e.record is the unsaved, never-persisted FamilyMerchant the failed
    # conversion tried to create. Replacing @family_merchant with it (as a
    # naive rescue would) breaks the re-rendered form: _form.html.erb picks
    # its action URL from `family_merchant.persisted?`, so an unpersisted
    # record posts to the FamilyMerchant#create route instead of back to
    # this ProviderMerchant's #update -- silently dropping the whole
    # conversion (transaction reassignment, user_modified protection) on
    # the next submit. Keep @merchant/@family_merchant pointed at the
    # original, persisted ProviderMerchant so the form still targets
    # #update; copy over the failed attempt's errors and submitted values
    # so the user sees what they typed and why it failed.
    restore_merchant_after_failed_conversion!
    e.record.errors.each { |error| @merchant.errors.add(error.attribute, error.type, **error.options) }
    render :edit, status: :unprocessable_entity
  rescue ActiveRecord::RecordNotUnique
    # Same race as above, surfaced through the raw DB constraint instead of
    # the Rails-level validation: two concurrent conversions in the same
    # family both passed uniqueness before either committed.
    restore_merchant_after_failed_conversion!
    @merchant.errors.add(:iban, :taken)
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
    def set_merchant
      # Find merchant that either belongs to family OR is assigned to family's transactions
      @merchant = Current.family.merchants.find_by(id: params[:id]) ||
                  Current.family.assigned_merchants.find(params[:id])
      @family_merchant = @merchant # For backwards compatibility with views
    end

    def merchant_params
      # Handle both family_merchant and provider_merchant param keys
      key = params.key?(:family_merchant) ? :family_merchant : :provider_merchant
      params.require(key).permit(:name, :color, :website_url, :iban)
    end

    # So a submitted value can be compared against the persisted
    # (already-normalized) iban without saving first.
    def normalize_iban(value)
      IbanNormalizable.normalize(value)
    end

    def render_create_error
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

    # Keeps @merchant/@family_merchant pointed at the original, persisted
    # ProviderMerchant after a failed conversion attempt (see the #update
    # rescues), instead of an unpersisted FamilyMerchant that would break
    # the re-rendered form's submit target. Restores every attribute the
    # form could have submitted, including :color -- merchant_params
    # permits it and convert_to_family_merchant_for receives it, so omitting
    # it here would silently revert a color change on the failed attempt.
    def restore_merchant_after_failed_conversion!
      @merchant.assign_attributes(merchant_params.slice(:name, :color, :website_url, :iban))
    end

    def render_create_error
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

    # Keeps @merchant/@family_merchant pointed at the original, persisted
    # ProviderMerchant after a failed conversion attempt (see the #update
    # rescues), instead of an unpersisted FamilyMerchant that would break
    # the re-rendered form's submit target. Restores every attribute the
    # form could have submitted, including :color -- merchant_params
    # permits it and convert_to_family_merchant_for receives it, so omitting
    # it here would silently revert a color change on the failed attempt.
    def restore_merchant_after_failed_conversion!
      @merchant.assign_attributes(merchant_params.slice(:name, :color, :website_url, :iban))
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
