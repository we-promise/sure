# The purchases module: what family members bought, from forwarded order emails and receipts.
class PurchasesController < ApplicationController
  before_action :require_preview_features!
  before_action :set_purchase, except: :index
  before_action :ensure_can_change, only: %i[dismiss reprocess apply_categories]

  def index
    @tab = params[:tab] == "to_match" ? "to_match" : "all"
    @query = params[:q].to_s.strip
    @summary = Purchase::Summary.new(visible_purchases, currency: Current.family.currency).call
    @to_match_count = @summary.to_match_count

    scope = visible_purchases.includes(items: :category, linked_transaction: :merchant)
    scope = scope.to_match if @tab == "to_match"
    scope = search(scope) if @query.present?
    scope = scope.where(ordered_on: start_date..) if start_date
    scope = scope.where(ordered_on: ..end_date) if end_date
    @month_totals = Purchase::Summary.month_totals(scope, currency: Current.family.currency)
    @pagy, @purchases = pagy(scope.order(Arel.sql("purchases.ordered_on DESC NULLS LAST"), created_at: :desc), limit: 25)
  end

  def show
    @entry = @purchase.linked_transaction&.entry
    @entry = nil unless @entry && Current.accessible_entries.exists?(@entry.id)
  end

  def dismiss
    @purchase.dismiss!
    redirect_to purchase_path(@purchase), notice: t(".dismissed")
  end

  def reprocess
    if @purchase.failed? && @purchase.email?
      @purchase.reprocess!
      redirect_to purchase_path(@purchase), notice: t(".reprocessing")
    else
      redirect_to purchase_path(@purchase)
    end
  end

  def apply_categories
    @purchase.apply_categories!(Current.user)
    redirect_to purchase_path(@purchase), notice: t(".applied")
  rescue Purchase::LinkError
    redirect_to purchase_path(@purchase), alert: t("purchases.not_authorized")
  end

  def original_email
    # The email may hold a delivery address or phone number, so only its sender gets it.
    raise ActiveRecord::RecordNotFound unless @purchase.user_id == Current.user.id && @purchase.email? && @purchase.original_email.attached?

    send_data @purchase.original_email.download, filename: "order.eml", type: "message/rfc822", disposition: "attachment"
  end

  private
    def visible_purchases
      Purchase.visible_to(Current.user).where(family: Current.family)
    end

    def set_purchase
      @purchase = visible_purchases.find(params[:id])
    end

    def ensure_can_change
      redirect_to purchase_path(@purchase), alert: t("purchases.not_authorized") unless @purchase.changeable_by?(Current.user)
    end

    def search(scope)
      pattern = "%#{ActiveRecord::Base.sanitize_sql_like(@query)}%"
      scope.where(
        "purchases.merchant ILIKE :q OR purchases.order_number ILIKE :q OR EXISTS (" \
        "SELECT 1 FROM purchase_items WHERE purchase_items.purchase_id = purchases.id AND purchase_items.name ILIKE :q)",
        q: pattern
      )
    end

    def start_date
      Date.iso8601(params[:start_date]) if params[:start_date].present?
    rescue Date::Error
      nil
    end

    def end_date
      Date.iso8601(params[:end_date]) if params[:end_date].present?
    rescue Date::Error
      nil
    end
end
