class PocketsController < ApplicationController
  before_action :set_account
  before_action :require_depository_account
  before_action :set_pocket, only: %i[edit update destroy]
  before_action :set_available_tags, only: %i[new create edit update]

  def index
    redirect_to account_path(@account, tab: :pockets)
  end

  def new
    @pocket = @account.pockets.new(currency: @account.currency)
  end

  def create
    @pocket = @account.pockets.new(pocket_params)
    @pocket.currency = @account.currency

    if @pocket.save
      respond_to do |format|
        format.turbo_stream { render_pocket_streams(t("pockets.create.success")) }
        format.html { redirect_to account_path(@account, tab: :pockets), notice: t("pockets.create.success") }
      end
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @pocket.update(pocket_params)
      respond_to do |format|
        format.turbo_stream { render_pocket_streams(t("pockets.update.success")) }
        format.html { redirect_to account_path(@account, tab: :pockets), notice: t("pockets.update.success") }
      end
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @pocket.destroy

    respond_to do |format|
      format.turbo_stream { render_pocket_streams(t("pockets.destroy.success")) }
      format.html { redirect_to account_path(@account, tab: :pockets), notice: t("pockets.destroy.success") }
    end
  end

  private

    def render_pocket_streams(notice)
      render turbo_stream: [
        turbo_stream.replace("modal", ""),
        turbo_stream.replace(
          ActionView::RecordIdentifier.dom_id(@account, :pockets_content),
          partial: "accounts/pockets/index",
          locals: { account: @account }
        )
      ]
    end

    def set_account
      @account = Current.user.accessible_accounts.find(params[:account_id])
    end

    def require_depository_account
      redirect_to account_path(@account), status: :see_other unless @account.depository?
    end

    def set_pocket
      @pocket = @account.pockets.find(params[:id])
    end

    def set_available_tags
      already_linked_tag_ids = @account.pockets.where.not(tag_id: nil).pluck(:tag_id)
      already_linked_tag_ids -= [ @pocket&.tag_id ].compact

      @available_tags = Current.family.tags
        .alphabetically
        .where.not(id: already_linked_tag_ids)
    end

    def pocket_params
      params.require(:pocket).permit(:name, :allocated_amount, :tag_id, :fill_direction)
    end
end
