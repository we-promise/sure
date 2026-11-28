# frozen_string_literal: true

class Api::V1::SecurityPricesController < Api::V1::BaseController
  include Pagy::Backend
  include Api::V1::SecurityResourceScoping

  before_action :ensure_read_scope, only: %i[index show]
  before_action :ensure_write_scope, only: :create
  before_action :ensure_self_hosted, only: :create
  before_action :reject_guest_writes!, only: :create
  before_action :set_security_price, only: :show
  before_action :set_search, only: :index

  def index
    security_prices_query = @search.security_prices_scope.order(date: :desc, created_at: :desc)
    @per_page = safe_per_page_param

    @pagy, @security_prices = pagy(
      security_prices_query,
      page: safe_page_param,
      limit: @per_page
    )

    render :index
  end

  def show
    render :show
  end

  # Stores closing prices for one security no provider tracks, traded in an
  # account the caller can write to, or held in a linked one.
  # The rows are shared by every family holding that security, which is why
  # this is limited to self-hosted instances.
  def create
    security, accounts = writable_security_and_accounts

    @result = security.import_manual_prices!(price_rows, accounts: accounts)
    @security = security
    accounts.find_each(&:sync_later)

    render :create
  rescue Security::ManualPriceImport::Invalid => e
    render_json({ error: "validation_failed", message: "Prices were not imported", errors: e.errors }, status: :unprocessable_entity)
  end

  private
    def ensure_write_scope
      authorize_scope!(:write)
    end

    def ensure_self_hosted
      return if self_hosted?

      render_json({
        error: "self_hosted_only",
        message: "Security prices are shared across families, so importing them is only available on self-hosted instances"
      }, status: :forbidden)
    end

    # The security and the caller's writable accounts eligible to price it.
    # Unknown, malformed and unreachable ids all get the same 404.
    def writable_security_and_accounts
      security_id = params.require(:security_id).to_s
      security = Security.find_by(id: security_id) if valid_uuid?(security_id)
      accounts = writable_accounts_referencing(security) if security
      raise ActiveRecord::RecordNotFound, "Security not found" unless accounts&.exists?

      [ security, accounts ]
    end

    # Only accounts whose position survives the sync this request queues: one
    # with a trade in the security, or a linked account, whose holdings come
    # from its provider and whose reverse sync never purges. An unlinked
    # account's forward sync rebuilds holdings from trades and deletes every
    # other non-provider row (Holding::Materializer#purge_stale_holdings), so
    # a holding no trade backs would be removed rather than revalued.
    def writable_accounts_referencing(security)
      writable = current_resource_owner.family.accounts.visible.writable_by(current_resource_owner).select(:id)
      traded = Account.where(id: Trade.joins(:entry).where(security: security).select("entries.account_id"))
      provider_held = Account.where(id: Holding.where(security: security).select(:account_id))
        .where(id: Account.linked.select(:id))

      Account.where(id: writable).and(traded.or(provider_held))
    end

    def price_rows
      rows = params[:prices]
      unless rows.is_a?(Array)
        raise Security::ManualPriceImport::Invalid.new([ { index: nil, message: "prices must be a list" } ])
      end

      rows.map { |row| row.is_a?(ActionController::Parameters) ? row.permit(:date, :price, :currency).to_h : row }
    end

    def set_security_price
      raise ActiveRecord::RecordNotFound, "Security price not found" unless valid_uuid?(params[:id])

      @security_price = security_prices_scope.find(params[:id])
    end

    def security_prices_scope
      Security::Price
        .where(security_id: scoped_security_ids)
        .includes(:security)
    end

    def set_search
      @search = Security::Price::Search.new(security_prices_scope, filters: {
        security_id: uuid_filter_param(:security_id),
        currency: string_filter_param(:currency),
        start_date: date_filter_param(:start_date),
        end_date: date_filter_param(:end_date),
        provisional: boolean_filter_param(:provisional),
        carried_forward: boolean_filter_param(:carried_forward)
      })
    end
end
