class CommodityItemsController < ApplicationController
  before_action :set_item, only: %i[edit update destroy edit_location update_location]

  def new
    metal = Commodity.metals.find { |m| m.code == params[:code] }
    return redirect_to(new_commodity_path) unless metal

    form = Commodity::Item::FORMS.include?(params[:form]) ? params[:form] : "coin"
    @item = Commodity::Item.new(
      code: metal.code,
      form: form,
      fineness: metal.fineness_for(form),
      weight_unit: Current.user.commodity_weight_unit,
      purchase_date: Date.current,
      purchase_currency: Current.family.currency,
      account: writable_accounts.find { |a| a.id == params[:account_id] } || writable_accounts.first
    )
  end

  def create
    @item = Commodity::Item.new(item_params.except(:account_id))
    @item.account = target_account
    location = location_from_params
    @item.location = location unless location == :unchanged

    if @item.valid?
      Commodity::Item.transaction do
        @item.account.save! if @item.account.new_record?
        @item.location&.save! if @item.location&.new_record?
        @item.save!
      end
      @item.account.sync_later
      redirect_to account_path(@item.account, tab: "inventory"), notice: t(".success")
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    location = location_from_params

    saved = Commodity::Item.transaction do
      raise ActiveRecord::Rollback unless @item.update(item_params.except(:account_id, :code))

      unless location == :unchanged
        location.save! if location&.new_record?
        @item.move_to!(location, on: Date.current)
      end
      true
    end

    if saved
      @item.account.sync_later
      redirect_to account_path(@item.account, tab: "inventory"), notice: t(".success")
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    account = @item.account
    @item.destroy!
    account.sync_later
    redirect_to account_path(account, tab: "inventory"), notice: t(".success")
  end

  def edit_location
  end

  def update_location
    location = location_from_params
    moved_on = params.dig(:commodity_item, :moved_on).presence&.to_date || Date.current

    Commodity::Item.transaction do
      unless location == :unchanged
        location.save! if location&.new_record?
        @item.move_to!(location, on: moved_on)
      end
    end

    redirect_to account_path(@item.account, tab: "inventory"), notice: t(".success")
  rescue Date::Error
    redirect_to account_path(@item.account, tab: "inventory"), alert: t(".invalid_date")
  end

  private
    def set_item
      @item = Commodity::Item.where(account: Current.user.accessible_accounts).find(params[:id])
      require_account_permission!(@item.account)
    end

    def item_params
      params.require(:commodity_item).permit(
        :account_id, :code, :name, :form, :quantity, :weight_value, :weight_unit, :fineness,
        :serial_number, :manufacturer, :year, :dealer, :notes, :photo,
        :purchase_date, :purchase_currency, :metal_price_value, :metal_price_basis, :premium, :premium_basis,
        :vat, :shipping, :insurance, :sell_back_mode, :sell_back_value
      )
    end

    def writable_accounts
      @writable_accounts ||= Current.user.accessible_accounts.visible
        .where(accountable_type: "Commodity").order(:name).to_a
        .select { |account| account.permission_for(Current.user).in?([ :owner, :full_control ]) }
    end
    helper_method :writable_accounts

    # The chosen commodities account, or a new one when the user has none yet
    # (or picked "new account"). Unsaved until the item is valid.
    def target_account
      account_id = item_params[:account_id]
      existing = writable_accounts.find { |a| a.id == account_id } if account_id.present? && account_id != "new"
      existing ||= writable_accounts.first if account_id.blank? && writable_accounts.one?
      existing || Current.family.accounts.build(
        name: params[:new_account_name].presence || Commodity::DEFAULT_ACCOUNT_NAME,
        currency: Current.family.currency,
        balance: 0,
        owner: Current.user,
        accountable: Commodity.new
      )
    end

    # A location from the select, a new one typed by name, nil for "none", or
    # :unchanged when the form had no location fields.
    def location_from_params
      attrs = params.fetch(:commodity_item, {})
      return :unchanged unless attrs.key?(:location_id) || attrs.key?(:new_location_name)

      if (name = attrs[:new_location_name].to_s.squish).present?
        Current.family.commodity_locations.where("lower(name) = ?", name.downcase).first ||
          Current.family.commodity_locations.build(name: name)
      elsif attrs[:location_id].present?
        Current.family.commodity_locations.find(attrs[:location_id])
      end
    end
end
