class KrakenItemsController < ApplicationController
  before_action :set_kraken_item, only: [ :show, :edit, :update, :destroy, :sync, :setup_accounts, :complete_account_setup ]
  before_action :require_admin!, only: [ :new, :create, :preload_accounts, :select_accounts, :link_accounts, :select_existing_account, :link_existing_account, :edit, :update, :destroy, :sync, :setup_accounts, :complete_account_setup ]

  def index
    @kraken_items = Current.family.kraken_items.ordered
  end

  def show
  end

  def new
    @kraken_item = Current.family.kraken_items.build
  end

  def edit
  end

  def create
    @kraken_item = Current.family.kraken_items.build(kraken_item_params)
    @kraken_item.name ||= t(".default_name")

    if @kraken_item.save
      @kraken_item.set_kraken_institution_defaults!
      @kraken_item.sync_later

      if turbo_frame_request?
        flash.now[:notice] = t(".success")
        @kraken_items = Current.family.kraken_items.ordered
        render turbo_stream: [
          turbo_stream.replace(
            "kraken-providers-panel",
            partial: "settings/providers/kraken_panel",
            locals: { kraken_items: @kraken_items }
          ),
          *flash_notification_stream_items
        ]
      else
        redirect_to settings_providers_path, notice: t(".success"), status: :see_other
      end
    else
      render_provider_error
    end
  end

  def update
    if @kraken_item.update(kraken_item_params)
      if turbo_frame_request?
        flash.now[:notice] = t(".success")
        @kraken_items = Current.family.kraken_items.ordered
        render turbo_stream: [
          turbo_stream.replace(
            "kraken-providers-panel",
            partial: "settings/providers/kraken_panel",
            locals: { kraken_items: @kraken_items }
          ),
          *flash_notification_stream_items
        ]
      else
        redirect_to settings_providers_path, notice: t(".success"), status: :see_other
      end
    else
      render_provider_error
    end
  end

  def destroy
    @kraken_item.destroy_later
    redirect_to settings_providers_path, notice: t(".success")
  end

  def sync
    @kraken_item.sync_later unless @kraken_item.syncing?

    respond_to do |format|
      format.html { redirect_back_or_to accounts_path }
      format.json { head :ok }
    end
  end

  def preload_accounts
    redirect_to settings_providers_path
  end

  def select_accounts
    redirect_to settings_providers_path
  end

  def link_accounts
    redirect_to settings_providers_path
  end

  def select_existing_account
    @account = Current.family.accounts.find(params[:account_id])
    @available_kraken_accounts = Current.family.kraken_items
      .includes(kraken_accounts: [ :account, { account_provider: :account } ])
      .flat_map(&:kraken_accounts)
      .select { |account| account.account.present? || account.account_provider.nil? }
      .sort_by { |account| account.updated_at || account.created_at }
  end

  def link_existing_account
    @account = Current.family.accounts.find(params[:account_id])

    kraken_account = Current.family.kraken_items
      .joins(:kraken_accounts)
      .where(kraken_accounts: { id: params[:kraken_account_id] })
      .first&.kraken_accounts&.find_by(id: params[:kraken_account_id])

    unless kraken_account
      flash[:alert] = t(".errors.invalid_kraken_account")
      return respond_to_link_existing_error
    end

    if @account.account_providers.any? || @account.plaid_account_id.present? || @account.simplefin_account_id.present?
      flash[:alert] = t(".errors.only_manual")
      return respond_to_link_existing_error
    end

    Account.transaction do
      kraken_account.lock!

      account_provider = AccountProvider.find_or_initialize_by(provider: kraken_account)
      previous_account = account_provider.account
      account_provider.account_id = @account.id
      account_provider.save!

      if previous_account && previous_account.id != @account.id && previous_account.family_id == @account.family_id
        previous_account.reload
        previous_account.destroy_later if previous_account.account_providers.none? && previous_account.may_mark_for_deletion?
      end
    end

    if turbo_frame_request?
      kraken_account.reload
      item = kraken_account.kraken_item
      item.reload

      @manual_accounts = Account.uncached do
        Current.family.accounts.visible_manual.order(:name).to_a
      end
      @kraken_items = Current.family.kraken_items.ordered.includes(:syncs)

      flash[:notice] = t(".success")
      @account.reload
      manual_accounts_stream = if @manual_accounts.any?
        turbo_stream.update(
          "manual-accounts",
          partial: "accounts/index/manual_accounts",
          locals: { accounts: @manual_accounts }
        )
      else
        turbo_stream.replace("manual-accounts", view_context.tag.div(id: "manual-accounts"))
      end

      render turbo_stream: [
        turbo_stream.replace(
          ActionView::RecordIdentifier.dom_id(item),
          partial: "kraken_items/kraken_item",
          locals: { kraken_item: item }
        ),
        manual_accounts_stream,
        *Array(flash_notification_stream_items)
      ]
    else
      redirect_to accounts_path, notice: t(".success")
    end
  end

  def setup_accounts
    @kraken_accounts = @kraken_item.kraken_accounts
      .left_joins(:account_provider)
      .where(account_providers: { id: nil })
      .order(:name)
  end

  def complete_account_setup
    selected_accounts = Array(params[:selected_accounts]).reject(&:blank?)
    created_accounts = []

    selected_accounts.each do |kraken_account_id|
      kraken_account = @kraken_item.kraken_accounts.find_by(id: kraken_account_id)
      next unless kraken_account

      kraken_account.with_lock do
        next if kraken_account.account.present?

        account = Account.create_from_kraken_account(kraken_account)
        kraken_account.ensure_account_provider!(account)
        created_accounts << account
      end

      kraken_account.reload
      KrakenAccount::HoldingsProcessor.new(kraken_account).process
    end

    unlinked_remaining = @kraken_item.kraken_accounts
      .left_joins(:account_provider)
      .where(account_providers: { id: nil })
      .count
    @kraken_item.update!(pending_account_setup: unlinked_remaining > 0)

    if created_accounts.any?
      flash[:notice] = t(".success", count: created_accounts.count)
    elsif selected_accounts.empty?
      flash[:notice] = t(".none_selected")
    else
      flash[:notice] = t(".no_accounts")
    end

    @kraken_item.sync_later if created_accounts.any?

    if turbo_frame_request?
      @kraken_items = Current.family.kraken_items.ordered.includes(:syncs)

      render turbo_stream: [
        turbo_stream.replace(
          ActionView::RecordIdentifier.dom_id(@kraken_item),
          partial: "kraken_items/kraken_item",
          locals: { kraken_item: @kraken_item }
        )
      ] + Array(flash_notification_stream_items)
    else
      redirect_to accounts_path, status: :see_other
    end
  end

  private

    def set_kraken_item
      @kraken_item = Current.family.kraken_items.find(params[:id])
    end

    def kraken_item_params
      params.require(:kraken_item).permit(
        :name,
        :sync_start_date,
        :api_key,
        :api_secret
      )
    end

    def render_provider_error
      @error_message = @kraken_item.errors.full_messages.join(", ")

      if turbo_frame_request?
        render turbo_stream: turbo_stream.replace(
          "kraken-providers-panel",
          partial: "settings/providers/kraken_panel",
          locals: { error_message: @error_message }
        ), status: :unprocessable_entity
      else
        redirect_to settings_providers_path, alert: @error_message, status: :unprocessable_entity
      end
    end

    def respond_to_link_existing_error
      if turbo_frame_request?
        render turbo_stream: Array(flash_notification_stream_items)
      else
        redirect_to account_path(@account), alert: flash[:alert]
      end
    end
end
