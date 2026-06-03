class EnvelopesController < ApplicationController
  before_action :require_preview_features!
  before_action :set_envelope, only: %i[show edit update destroy]
  rescue_from ActiveRecord::RecordNotFound, with: :envelope_not_found

  def index
    @envelopes = Current.family.envelopes.alphabetically.includes(category: :subcategories).to_a
    @negative_count = @envelopes.count(&:negative?)
    @breadcrumbs = [
      [ t("breadcrumbs.home"), root_path ],
      [ t("envelopes.index.title"), nil ]
    ]
  end

  def show
    @recent_entries = @envelope.recent_entries.to_a
    @breadcrumbs = [
      [ t("breadcrumbs.home"), root_path ],
      [ t("envelopes.index.title"), envelopes_path ],
      [ @envelope.name, nil ]
    ]
  end

  def new
    @envelope = Current.family.envelopes.new(
      color: Envelope::COLORS.sample,
      currency: Current.family.primary_currency_code,
      starts_on: Date.current.beginning_of_month
    )
    @categories = assignable_categories
    @breadcrumbs = [
      [ t("breadcrumbs.home"), root_path ],
      [ t("envelopes.index.title"), envelopes_path ],
      [ t("envelopes.new.heading"), nil ]
    ]
  end

  def create
    @envelope = Current.family.envelopes.new(envelope_params)
    @envelope.save!

    flash[:notice] = t(".success")
    respond_to do |format|
      format.html { redirect_to envelope_path(@envelope) }
      format.turbo_stream { render turbo_stream: turbo_stream.action(:redirect, envelope_path(@envelope)) }
    end
  rescue ActiveRecord::RecordInvalid
    @categories = assignable_categories
    render :new, status: :unprocessable_entity
  end

  def edit
    @categories = assignable_categories
  end

  def update
    @envelope.update!(envelope_params)

    flash[:notice] = t(".success")
    respond_to do |format|
      format.html { redirect_to envelope_path(@envelope) }
      format.turbo_stream { render turbo_stream: turbo_stream.action(:redirect, envelope_path(@envelope)) }
    end
  rescue ActiveRecord::RecordInvalid
    @categories = assignable_categories
    render :edit, status: :unprocessable_entity
  end

  def destroy
    @envelope.destroy!
    redirect_to envelopes_path, notice: t(".success")
  end

  private
    def set_envelope
      @envelope = Current.family.envelopes.includes(category: :subcategories).find(params[:id])
    end

    def envelope_not_found
      redirect_to envelopes_path, alert: t("envelopes.errors.not_found")
    end

    def envelope_params
      params.require(:envelope).permit(
        :name, :category_id, :monthly_contribution, :currency,
        :target_amount, :target_date, :starts_on, :color, :icon, :notes
      )
    end

    # Categories the form may offer: everything in the family minus the ones
    # already backing another envelope (the model enforces one envelope per
    # category). The envelope being edited keeps its own category in the list.
    def assignable_categories
      taken_ids = Current.family.envelopes
                         .where.not(category_id: nil)
                         .where.not(id: @envelope&.id)
                         .select(:category_id)
      Current.family.categories.alphabetically.where.not(id: taken_ids).to_a
    end
end
