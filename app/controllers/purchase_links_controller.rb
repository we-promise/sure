# Links a purchase to the transaction that paid for it by hand, or undoes the link.
class PurchaseLinksController < ApplicationController
  PICKER_LIMIT = 50
  PICKER_DAYS = 90

  before_action :require_preview_features!
  before_action :set_purchase
  before_action :ensure_can_change

  def new
    @query = params[:q].to_s.strip
    @candidates = candidates
    @entries = @query.present? ? search : []
    render layout: turbo_frame_request? ? false : "application"
  end

  def create
    entry = Current.annotatable_entries.where(entryable_type: "Transaction").find(params[:entry_id])
    @purchase.link!(entry, manual: true)
    redirect_to purchase_path(@purchase), notice: t(".linked")
  rescue Purchase::LinkError
    redirect_to purchase_path(@purchase), alert: t(".not_linkable")
  end

  def destroy
    @purchase.unlink!
    redirect_to purchase_path(@purchase), notice: t(".unlinked")
  end

  private
    def set_purchase
      @purchase = Purchase.visible_to(Current.user).where(family: Current.family).find(params[:purchase_id])
    end

    def ensure_can_change
      redirect_to purchase_path(@purchase), alert: t("purchases.not_authorized") unless @purchase.changeable_by?(Current.user)
    end

    def transaction_entries
      Current.annotatable_entries.where(entryable_type: "Transaction").where(parent_entry_id: nil).includes(:account)
    end

    def candidates
      ids = @purchase.match_candidate_entry_ids | Purchase::Matcher.new(@purchase).result.entries.map(&:id)
      transaction_entries.where(id: ids)
        .where.not(entryable_id: Purchase.where.not(transaction_id: nil).where.not(id: @purchase.id).select(:transaction_id))
        .order(:date)
    end

    def search
      pattern = "%#{ActiveRecord::Base.sanitize_sql_like(@query)}%"
      around = @purchase.ordered_on || Date.current
      transaction_entries
        .where("entries.name ILIKE ?", pattern)
        .where(date: (around - PICKER_DAYS)..(around + PICKER_DAYS))
        .order(date: :desc)
        .limit(PICKER_LIMIT)
    end
end
