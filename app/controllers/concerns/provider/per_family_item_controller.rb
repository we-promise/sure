# Base controller concern for per-family provider item CRUD operations
#
# This concern provides standard create, update, and destroy actions for
# per-family provider items, along with turbo stream responses for inline updates.
#
# Example usage in a controller:
#   class LunchflowItemsController < ApplicationController
#     include Provider::PerFamilyItemController
#
#     # Optionally override methods:
#     # - item_model_class (defaults to LunchflowItem)
#     # - provider_key (defaults to :lunchflow)
#     # - panel_turbo_frame_id (defaults to "lunchflow-providers-panel")
#     # - default_item_name (defaults to "Lunchflow Connection")
#     # - permitted_params (defaults to fields from configuration)
#   end
module Provider::PerFamilyItemController
  extend ActiveSupport::Concern

  included do
    before_action :set_item, only: [:show, :edit, :update, :destroy, :sync]
  end

  # GET /provider_items (optional, for index view)
  def index
    @items = Current.family.send(items_association_name).active.ordered
    render layout: "settings"
  end

  # GET /provider_items/:id (optional, for show view)
  def show
  end

  # GET /provider_items/new (optional, for new form)
  def new
    @item = Current.family.send(items_association_name).build
  end

  # POST /provider_items
  def create
    @item = Current.family.send(items_association_name).build(permitted_params)
    @item.name ||= default_item_name

    if @item.save
      handle_successful_save(:create)
    else
      handle_failed_save(:create)
    end
  end

  # GET /provider_items/:id/edit (optional, for edit form)
  def edit
  end

  # PATCH/PUT /provider_items/:id
  def update
    if @item.update(permitted_params)
      handle_successful_save(:update)
    else
      handle_failed_save(:update)
    end
  end

  # DELETE /provider_items/:id (optional, can be overridden for custom destroy logic)
  def destroy
    @item.destroy_later if @item.respond_to?(:destroy_later)
    @item.destroy unless @item.respond_to?(:destroy_later)

    redirect_to accounts_path, notice: t(".success", default: "#{provider_key.titleize} connection removed successfully")
  end

  # POST /provider_items/:id/sync (optional, for manual sync)
  def sync
    unless @item.syncing?
      @item.sync_later if @item.respond_to?(:sync_later)
    end

    respond_to do |format|
      format.html { redirect_back_or_to accounts_path }
      format.json { head :ok }
    end
  end

  private

  # Override in controller to customize item model class
  def item_model_class
    @item_model_class ||= self.class.name.gsub(/Controller$/, "").singularize.constantize
  end

  # Override in controller to customize provider key
  def provider_key
    @provider_key ||= self.class.name.gsub(/ItemsController$/, "").demodulize.underscore.to_sym
  end

  # Override in controller to customize items association name
  def items_association_name
    @items_association_name ||= "#{provider_key}_items".to_sym
  end

  # Override in controller to customize turbo frame ID
  def panel_turbo_frame_id
    @panel_turbo_frame_id ||= "#{provider_key}-providers-panel"
  end

  # Override in controller to customize default item name
  def default_item_name
    "#{provider_key.to_s.titleize} Connection"
  end

  # Override in controller to customize permitted parameters
  def permitted_params
    # Get permitted params from the per-family configuration
    adapter_class = "Provider::#{provider_key.to_s.camelize}Adapter".constantize
    config = adapter_class.per_family_configuration

    if config
      param_key = "#{provider_key}_item".to_sym
      field_names = config.fields.map(&:name)
      params.require(param_key).permit(:name, :sync_start_date, *field_names)
    else
      # Fallback to basic params if no configuration found
      param_key = "#{provider_key}_item".to_sym
      params.require(param_key).permit(:name, :sync_start_date)
    end
  rescue ActionController::ParameterMissing
    {}
  end

  def set_item
    @item = Current.family.send(items_association_name).find(params[:id])
  end

  # Handle successful save (create or update)
  def handle_successful_save(action)
    if turbo_frame_request?
      flash.now[:notice] = t(".success", default: "Configuration #{action == :create ? 'saved' : 'updated'} successfully")
      @items = Current.family.send(items_association_name).ordered

      render turbo_stream: [
        turbo_stream.replace(
          panel_turbo_frame_id,
          partial: "settings/providers/#{provider_key}_panel",
          locals: { "#{items_association_name}": @items }
        ),
        *flash_notification_stream_items
      ]
    else
      redirect_to accounts_path,
                  notice: t(".success", default: "Configuration #{action == :create ? 'saved' : 'updated'} successfully"),
                  status: :see_other
    end
  end

  # Handle failed save (create or update)
  def handle_failed_save(action)
    @error_message = @item.errors.full_messages.join(", ")

    if turbo_frame_request?
      render turbo_stream: turbo_stream.replace(
        panel_turbo_frame_id,
        partial: "settings/providers/#{provider_key}_panel",
        locals: { error_message: @error_message }
      ), status: :unprocessable_entity
    else
      if action == :create
        render :new, status: :unprocessable_entity
      else
        render :edit, status: :unprocessable_entity
      end
    end
  end
end
