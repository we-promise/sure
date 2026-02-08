# frozen_string_literal: true

class Api::V1::TradesController < Api::V1::BaseController
  include Pagy::Backend

  before_action :ensure_read_scope, only: [ :index, :show ]
  before_action :ensure_write_scope, only: [ :create, :update, :destroy ]
  before_action :set_trade, only: [ :show, :update, :destroy ]

  def index
    family = current_resource_owner.family
    trades_query = family.trades.visible

    trades_query = apply_filters(trades_query)
    trades_query = trades_query.includes({ entry: :account }, :security, :category).reverse_chronological

    @pagy, @trades = pagy(
      trades_query,
      page: safe_page_param,
      limit: safe_per_page_param
    )
    @per_page = safe_per_page_param

    render :index
  rescue ArgumentError => e
    render_validation_error(e.message, [ e.message ])
  rescue => e
    log_and_render_error("index", e)
  end

  def show
    render :show
  rescue => e
    log_and_render_error("show", e)
  end

  def create
    unless trade_params[:account_id].present?
      return render_validation_error("Account ID is required", [ "Account ID is required" ])
    end

    account = current_resource_owner.family.accounts.visible.find(trade_params[:account_id])

    unless account.supports_trades?
      return render_validation_error(
        "Account does not support trades (investment or crypto exchange only)",
        [ "Account must be an investment or crypto exchange account" ]
      )
    end

    create_params = build_create_form_params(account)
    return if performed? # build_create_form_params may have rendered validation errors

    model = Trade::CreateForm.new(create_params).create

    unless model.persisted?
      errors = model.is_a?(Entry) ? model.errors.full_messages : [ "Trade could not be created" ]
      return render_validation_error("Trade could not be created", errors)
    end

    if model.is_a?(Entry)
      model.lock_saved_attributes!
      model.mark_user_modified!
      model.sync_account_later
      @trade = model.trade
    else
      @trade = model
    end

    apply_trade_create_options!
    return if performed?

    @entry = @trade.entry
    render :show, status: :created
  rescue ActiveRecord::RecordNotFound => e
    message = (e.model == "Account") ? "Account not found" : "Security not found"
    render json: { error: "not_found", message: message }, status: :not_found
  rescue => e
    log_and_render_error("create", e)
  end

  def update
    updatable = build_entry_params_for_update

    if @entry.update(updatable.except(:nature))
      @entry.lock_saved_attributes!
      @entry.mark_user_modified!
      @entry.sync_account_later
      @trade = @entry.trade
      render :show
    else
      render_validation_error("Trade could not be updated", @entry.errors.full_messages)
    end
  rescue => e
    log_and_render_error("update", e)
  end

  def destroy
    @entry = @trade.entry
    @entry.destroy!
    @entry.sync_account_later

    render json: { message: "Trade deleted successfully" }, status: :ok
  rescue => e
    log_and_render_error("destroy", e)
  end

  private

    def set_trade
      family = current_resource_owner.family
      @trade = family.trades.visible.find(params[:id])
      @entry = @trade.entry
    rescue ActiveRecord::RecordNotFound
      render json: { error: "not_found", message: "Trade not found" }, status: :not_found
    end

    def ensure_read_scope
      authorize_scope!(:read)
    end

    def ensure_write_scope
      authorize_scope!(:write)
    end

    def apply_filters(query)
      need_entry_join = params[:account_id].present? || params[:account_ids].present? ||
                        params[:start_date].present? || params[:end_date].present?
      query = query.joins(:entry) if need_entry_join

      if params[:account_id].present?
        query = query.where(entries: { account_id: params[:account_id] })
      end
      if params[:account_ids].present?
        query = query.where(entries: { account_id: Array(params[:account_ids]) })
      end
      if params[:start_date].present?
        query = query.where("entries.date >= ?", parse_date!(params[:start_date], "start_date"))
      end
      if params[:end_date].present?
        query = query.where("entries.date <= ?", parse_date!(params[:end_date], "end_date"))
      end
      query
    end

    def trade_params
      params.require(:trade).permit(
        :account_id, :date, :qty, :price, :currency,
        :security_id, :ticker, :manual_ticker, :investment_activity_label, :category_id
      )
    end

    def trade_update_params
      params.require(:trade).permit(
        :name, :date, :amount, :currency, :notes, :nature, :type,
        :qty, :price, :investment_activity_label, :category_id
      )
    end

    def build_entry_params_for_update
      flat = trade_update_params.to_h
      entry_params = {
        name: flat[:name],
        date: flat[:date],
        amount: flat[:amount],
        currency: flat[:currency],
        notes: flat[:notes],
        entryable_type: "Trade",
        entryable_attributes: {
          id: @trade.id,
          investment_activity_label: flat[:investment_activity_label],
          category_id: flat[:category_id]
        }.compact_blank
      }.compact

      original_qty = flat[:qty]
      original_price = flat[:price]
      type_or_nature = flat[:type].presence || flat[:nature]

      if original_qty.present? || original_price.present?
        qty = original_qty.present? ? original_qty : @trade.qty.abs
        price = original_price.present? ? original_price : @trade.price
        is_sell = type_or_nature.present? ? trade_sell_from_type_or_nature?(type_or_nature) : @trade.qty.negative?
        signed_qty = is_sell ? -qty.to_d.abs : qty.to_d.abs
        entry_params[:entryable_attributes][:qty] = signed_qty
        entry_params[:amount] = signed_qty * price.to_d
        ticker = @trade.security&.ticker
        entry_params[:name] = Trade.build_name(is_sell ? "sell" : "buy", signed_qty.abs, ticker) if ticker.present?
        entry_params[:entryable_attributes][:investment_activity_label] = flat[:investment_activity_label].presence || @trade.investment_activity_label.presence || (is_sell ? "Sell" : "Buy")
      end

      entry_params
    end

    # True for sell: "sell" or "inflow". False for buy: "buy", "outflow", or blank. Keeps create (buy/sell) and update (type or nature) consistent.
    def trade_sell_from_type_or_nature?(value)
      return false if value.blank?

      normalized = value.to_s.downcase.strip
      %w[sell inflow].include?(normalized)
    end

    def build_create_form_params(account)
      type = params.dig(:trade, :type).to_s.downcase
      unless %w[buy sell].include?(type)
        render_validation_error("Type must be buy or sell", [ "type must be 'buy' or 'sell'" ])
        return nil
      end

      ticker_value = nil
      manual_ticker_value = nil

      unless trade_params[:date].present?
        render_validation_error("Date is required", [ "date must be present" ])
        return nil
      end

      if trade_params[:security_id].present?
        security = Security.find(trade_params[:security_id])
        ticker_value = security.exchange_operating_mic.present? ? "#{security.ticker}|#{security.exchange_operating_mic}" : security.ticker
      elsif trade_params[:ticker].present?
        ticker_value = trade_params[:ticker]
      elsif trade_params[:manual_ticker].present?
        manual_ticker_value = trade_params[:manual_ticker]
      else
        render_validation_error("Security identifier required", [ "Provide security_id, ticker, or manual_ticker" ])
        return nil
      end

      qty_raw = trade_params[:qty].to_s.strip
      price_raw = trade_params[:price].to_s.strip
      return render_validation_error("Quantity and price are required", [ "qty and price must be present and positive" ]) if qty_raw.blank? || price_raw.blank?

      qty = qty_raw.to_d
      price = price_raw.to_d
      if qty <= 0 || price <= 0
        # Non-numeric input (e.g. "abc") becomes 0 with to_d; give a clearer message than "must be present"
        non_numeric = (qty.zero? && qty_raw !~ /\A0(\.0*)?\z/) || (price.zero? && price_raw !~ /\A0(\.0*)?\z/)
        return render_validation_error("Quantity and price must be valid numbers", [ "qty and price must be valid positive numbers" ]) if non_numeric
        return render_validation_error("Quantity and price are required", [ "qty and price must be present and positive" ])
      end

      {
        account: account,
        date: trade_params[:date],
        qty: qty,
        price: price,
        currency: trade_params[:currency].presence || account.currency,
        type: type,
        ticker: ticker_value,
        manual_ticker: manual_ticker_value
      }.compact
    end

    def apply_trade_create_options!
      attrs = {}
      if trade_params[:investment_activity_label].present?
        label = trade_params[:investment_activity_label]
        unless Trade::ACTIVITY_LABELS.include?(label)
          render_validation_error("Invalid investment_activity_label", [ "investment_activity_label must be one of: #{Trade::ACTIVITY_LABELS.join(', ')}" ])
          return
        end
        attrs[:investment_activity_label] = label
      end
      if trade_params[:category_id].present?
        category = current_resource_owner.family.categories.find_by(id: trade_params[:category_id])
        unless category
          render_validation_error("Category not found or does not belong to your family", [ "category_id is invalid" ])
          return
        end
        attrs[:category_id] = category.id
      end
      @trade.update!(attrs) if attrs.any?
    end

    def render_validation_error(message, errors)
      render json: {
        error: "validation_failed",
        message: message,
        errors: errors
      }, status: :unprocessable_entity
    end

    def parse_date!(value, param_name)
      Date.parse(value)
    rescue Date::Error, ArgumentError, TypeError
      raise ArgumentError, "Invalid #{param_name} format"
    end

    def log_and_render_error(action, exception)
      Rails.logger.error "TradesController##{action} error: #{exception.message}"
      Rails.logger.error exception.backtrace.join("\n")
      render json: {
        error: "internal_server_error",
        message: "Error: #{exception.message}"
      }, status: :internal_server_error
    end

    def safe_page_param
      page = params[:page].to_i
      page > 0 ? page : 1
    end

    def safe_per_page_param
      per_page = params[:per_page].to_i
      case per_page
      when 1..100
        per_page
      else
        25
      end
    end
end
