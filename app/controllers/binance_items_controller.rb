# frozen_string_literal: true

class BinanceItemsController < ApplicationController
  before_action :set_binance_item, only: [ :show, :edit, :update, :destroy, :sync, :setup_accounts, :complete_account_setup ]
  before_action :require_admin!, only: [ :new, :create, :select_accounts, :link_accounts, :select_existing_account, :link_existing_account, :edit, :update, :destroy, :sync, :setup_accounts, :complete_account_setup ]

  def index
    @binance_items = Current.family.binance_items.ordered
  end

  def show
  end

  def new
    @binance_item = Current.family.binance_items.build
  end

  def edit
  end

  def create
    @binance_item = Current.family.binance_items.build(binance_item_params)
    @binance_item.name ||= t(".default_name")

    if @binance_item.save
      @binance_item.set_binance_institution_defaults!
      @binance_item.sync_later

      if turbo_frame_request?
        flash.now[:notice] = t(".success")
        @binance_items = Current.family.binance_items.ordered
        render turbo_stream: [
          turbo_stream.replace(
            "binance-providers-panel",
            partial: "settings/providers/binance_panel",
            locals: { binance_items: @binance_items }
          ),
          *flash_notification_stream_items
        ]
      else
        redirect_to settings_providers_path, notice: t(".success"), status: :see_other
      end
    else
      @error_message = @binance_item.errors.full_messages.join(", ")

      if turbo_frame_request?
        render turbo_stream: turbo_stream.replace(
          "binance-providers-panel",
          partial: "settings/providers/binance_panel",
          locals: { error_message: @error_message }
        ), status: :unprocessable_entity
      else
        redirect_to settings_providers_path, alert: @error_message, status: :unprocessable_entity
      end
    end
  end

  def update
    if @binance_item.update(binance_item_params)
      if turbo_frame_request?
        flash.now[:notice] = t(".success")
        @binance_items = Current.family.binance_items.ordered
        render turbo_stream: [
          turbo_stream.replace(
            "binance-providers-panel",
            partial: "settings/providers/binance_panel",
            locals: { binance_items: @binance_items }
          ),
          *flash_notification_stream_items
        ]
      else
        redirect_to settings_providers_path, notice: t(".success"), status: :see_other
      end
    else
      @error_message = @binance_item.errors.full_messages.join(", ")

      if turbo_frame_request?
        render turbo_stream: turbo_stream.replace(
          "binance-providers-panel",
          partial: "settings/providers/binance_panel",
          locals: { error_message: @error_message }
        ), status: :unprocessable_entity
      else
        redirect_to settings_providers_path, alert: @error_message, status: :unprocessable_entity
      end
    end
  end

  def destroy
    @binance_item.destroy_later
    redirect_to settings_providers_path, notice: t(".success")
  end

  def sync
    unless @binance_item.syncing?
      @binance_item.sync_later
    end

    respond_to do |format|
      format.html { redirect_back_or_to accounts_path }
      format.json { head :ok }
    end
  end

  def select_accounts
    redirect_to settings_providers_path
  end

  def link_accounts
    redirect_to settings_providers_path
  end

  def select_existing_account
    @account = Current.family.accounts.find(params[:account_id])

    @available_binance_accounts = Current.family.binance_items
      .includes(binance_accounts: [ :account, { account_provider: :account } ])
      .flat_map(&:binance_accounts)
      .select { |ba| ba.account.present? || ba.account_provider.nil? }
      .sort_by { |ba| ba.updated_at || ba.created_at }
      .reverse

    render :select_existing_account, layout: false
  end

  def link_existing_account
    @account = Current.family.accounts.find(params[:account_id])

    binance_account = Current.family.binance_items
      .joins(:binance_accounts)
      .where(binance_accounts: { id: params[:binance_account_id] })
      .first&.binance_accounts&.find_by(id: params[:binance_account_id])

    unless binance_account
      flash[:alert] = t(".errors.invalid_binance_account")
      if turbo_frame_request?
        render turbo_stream: Array(flash_notification_stream_items)
      else
        redirect_to account_path(@account), alert: flash[:alert]
      end
      return
    end

    if @account.account_providers.any? || @account.plaid_account_id.present? || @account.simplefin_account_id.present?
      flash[:alert] = t(".errors.only_manual")
      if turbo_frame_request?
        return render turbo_stream: Array(flash_notification_stream_items)
      else
        return redirect_to account_path(@account), alert: flash[:alert]
      end
    end

    Account.transaction do
      binance_account.lock!
      ap = AccountProvider.find_or_initialize_by(provider: binance_account)
      previous_account = ap.account
      ap.account_id = @account.id
      ap.save!

      if previous_account && previous_account.id != @account.id && previous_account.family_id == @account.family_id
        begin
          previous_account.reload
          if previous_account.account_providers.none?
            previous_account.destroy_later if previous_account.may_mark_for_deletion?
          end
        rescue => e
          Rails.logger.warn("Binance orphan cleanup failed for ##{previous_account&.id}: #{e.class} - #{e.message}")
        end
      end
    end

    if turbo_frame_request?
      item = binance_account.binance_item.reload
      @binance_items = Current.family.binance_items.ordered.includes(:syncs)
      @manual_accounts = Account.uncached { Current.family.accounts.visible_manual.order(:name).to_a }

      flash[:notice] = t(".success")
      manual_accounts_stream = if @manual_accounts.any?
        turbo_stream.update("manual-accounts", partial: "accounts/index/manual_accounts", locals: { accounts: @manual_accounts })
      else
        turbo_stream.replace("manual-accounts", view_context.tag.div(id: "manual-accounts"))
      end

      render turbo_stream: [
        turbo_stream.replace(
          ActionView::RecordIdentifier.dom_id(item),
          partial: "binance_items/binance_item",
          locals: { binance_item: item }
        ),
        manual_accounts_stream,
        *Array(flash_notification_stream_items)
      ]
    else
      redirect_to accounts_path, notice: t(".success")
    end
  end

  def setup_accounts
    @binance_accounts = @binance_item.binance_accounts
      .left_joins(:account_provider)
      .where(account_providers: { id: nil })
      .order(:name)
  end

  def complete_account_setup
    selected_accounts = Array(params[:selected_accounts]).reject(&:blank?)
    created_accounts = []

    selected_accounts.each do |binance_account_id|
      ba = @binance_item.binance_accounts.find_by(id: binance_account_id)
      next unless ba

      ba.with_lock do
        next if ba.account.present?

        account = Account.create_from_binance_account(ba)
        ba.ensure_account_provider!(account)
        created_accounts << account
      end

      ba.reload

      begin
        BinanceAccount::HoldingsProcessor.new(ba).process
      rescue => e
        Rails.logger.error("Failed to process holdings for #{ba.id}: #{e.message}")
      end
    end

    unlinked_remaining = @binance_item.binance_accounts
      .left_joins(:account_provider)
      .where(account_providers: { id: nil })
      .count
    @binance_item.update!(pending_account_setup: unlinked_remaining > 0)

    if created_accounts.any?
      flash[:notice] = t(".success", count: created_accounts.count)
    elsif selected_accounts.empty?
      flash[:notice] = t(".none_selected")
    else
      flash[:notice] = t(".no_accounts")
    end

    @binance_item.sync_later if created_accounts.any?

    if turbo_frame_request?
      @binance_items = Current.family.binance_items.ordered.includes(:syncs)
      render turbo_stream: [
        turbo_stream.replace(
          ActionView::RecordIdentifier.dom_id(@binance_item),
          partial: "binance_items/binance_item",
          locals: { binance_item: @binance_item }
        )
      ] + Array(flash_notification_stream_items)
    else
      redirect_to accounts_path, status: :see_other
    end
  end

  private

    def set_binance_item
      @binance_item = Current.family.binance_items.find(params[:id])
    end

    def binance_item_params
      params.require(:binance_item).permit(:name, :sync_start_date, :api_key, :api_secret)
    end
end
