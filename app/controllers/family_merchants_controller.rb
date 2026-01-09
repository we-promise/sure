class FamilyMerchantsController < ApplicationController
  before_action :set_merchant, only: %i[edit update destroy]

  def index
    @breadcrumbs = [ [ "Home", root_path ], [ "Merchants", nil ] ]

    # Show all merchants for this family
    @family_merchants = Current.family.merchants.alphabetically
    @provider_merchants = Current.family.assigned_merchants.where(type: "ProviderMerchant").alphabetically

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
      # Convert ProviderMerchant to FamilyMerchant for this family only
      @family_merchant = @merchant.convert_to_family_merchant_for(Current.family, merchant_params)
      respond_to do |format|
        format.html { redirect_to family_merchants_path, notice: t(".converted_success") }
        format.turbo_stream { render turbo_stream: turbo_stream.action(:redirect, family_merchants_path) }
      end
    else
      @merchant.update!(merchant_params)
      respond_to do |format|
        format.html { redirect_to family_merchants_path, notice: t(".success") }
        format.turbo_stream { render turbo_stream: turbo_stream.action(:redirect, family_merchants_path) }
      end
    end
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

  def merge
    @merchants = all_family_merchants
  end

  def perform_merge
    target = Merchant.find(params[:target_id])
    sources = Merchant.where(id: params[:source_ids])

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
  end

  private
    def set_merchant
      # Find merchant that either belongs to family OR is assigned to family's transactions
      @merchant = Current.family.merchants.find_by(id: params[:id]) ||
                  Current.family.assigned_merchants.find(params[:id])
      @family_merchant = @merchant # For backwards compatibility with views
    end

    def merchant_params
      params.require(:family_merchant).permit(:name, :color)
    end

    def all_family_merchants
      (Current.family.merchants.to_a + Current.family.assigned_merchants.where(type: "ProviderMerchant").to_a)
        .uniq(&:id)
        .sort_by { |m| m.name.downcase }
    end
end
