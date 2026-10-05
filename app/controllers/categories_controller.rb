class CategoriesController < ApplicationController
  before_action :set_category, only: %i[edit update destroy]
  before_action :set_categories, only: %i[update edit]
  before_action :set_transaction, only: :create
  before_action :require_admin!, only: :toggle_lock
  before_action :ensure_categories_unlocked, only: %i[create bootstrap]

  def index
    @categories = Current.family.categories.alphabetically_by_hierarchy.to_a
    @category_groups = Category::Group.for(@categories)
    @category_ids_with_transactions = Category.ids_with_transactions(
      family: Current.family,
      category_ids: @categories.map(&:id)
    )

    render layout: "settings"
  end

  def new
    return render :locked if Current.family.categories_locked?

    @category = Current.family.categories.new color: Category::COLORS.sample
    set_categories
  end

  def merge
    @categories = Current.family.categories.alphabetically_by_hierarchy

    render layout: turbo_frame_request? ? false : "settings"
  end

  def create
    @category = Current.family.categories.new(category_params)

    if @category.save
      if @transaction
        @transaction.update(category_id: @category.id)
        @transaction.record_category_usage!
      end

      redirect_target_url = request.referer || categories_path

      respond_to do |format|
        format.html { redirect_back_or_to categories_path, notice: t(".success") }

        format.turbo_stream do
          flash[:notice] = t(".success")
          render turbo_stream: turbo_stream.action(:redirect, redirect_target_url)
        end

        format.json { render json: category_json(@category), status: :created }
      end
    else
      respond_to do |format|
        format.html do
          set_categories
          render :new, status: :unprocessable_entity
        end

        format.turbo_stream do
          set_categories
          render :new, formats: [ :html ], status: :unprocessable_entity
        end

        format.json do
          render json: { errors: @category.errors.full_messages },
                 status: :unprocessable_entity
        end
      end
    end
  end

  def edit
  end

  def update
    if @category.update(category_params)
      flash[:notice] = t(".success")

      redirect_target_url = request.referer || categories_path
      respond_to do |format|
        format.html { redirect_back_or_to categories_path, notice: t(".success") }
        format.turbo_stream { render turbo_stream: turbo_stream.action(:redirect, redirect_target_url) }
      end
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @category.destroy

    redirect_back_or_to categories_path, notice: t(".success")
  end

  def destroy_all
    Current.family.categories.destroy_all
    redirect_back_or_to categories_path, notice: t(".success")
  end

  def bootstrap
    Current.family.categories.bootstrap!

    redirect_back_or_to categories_path, notice: t(".success")
  end

  def toggle_lock
    locked = params.require(:locked) == "true"
    Current.family.update!(categories_locked: locked)

    redirect_back_or_to categories_path, notice: locked ? t(".locked") : t(".unlocked")
  end

  def perform_merge
    permitted_params = category_merge_params

    if permitted_params[:target_id].present? && Array(permitted_params[:source_ids]).include?(permitted_params[:target_id])
      return redirect_to merge_categories_path, alert: t(".target_selected_as_source")
    end

    target = Current.family.categories.find_by(id: permitted_params[:target_id])
    return redirect_to merge_categories_path, alert: t(".target_not_found") unless target

    sources = Current.family.categories.where(id: permitted_params[:source_ids])
    return redirect_to merge_categories_path, alert: t(".invalid_categories") unless sources.any?

    merger = Category::Merger.new(family: Current.family, target_category: target, source_categories: sources)
    return redirect_to merge_categories_path, alert: t(".no_categories_selected") unless merger.merge!

    redirect_to categories_path, notice: t(".success", count: merger.merged_count)
  rescue Category::Merger::UnauthorizedCategoryError => e
    redirect_to merge_categories_path, alert: e.message
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotDestroyed => e
    redirect_to merge_categories_path, alert: record_error_message(e)
  end

  private
    def set_category
      @category = Current.family.categories.find(params[:id])
    end

    def ensure_categories_unlocked
      return unless Current.family.categories_locked?

      respond_to do |format|
        format.html { redirect_back_or_to categories_path, alert: categories_locked_message }
        format.turbo_stream { redirect_to categories_path, alert: categories_locked_message }
        format.json { render json: { errors: categories_locked_errors }, status: :unprocessable_entity }
        format.any { head :forbidden }
      end
    end

    def categories_locked_message
      if Current.user.admin?
        t("categories.locked")
      else
        t("categories.index.locked_message")
      end
    end

    def categories_locked_errors
      [ categories_locked_message ]
    end

    def set_categories
      @categories = unless @category.parent?
        Current.family.categories.alphabetically.roots.where.not(id: @category.id)
      else
        []
      end
    end

    def set_transaction
      if params[:transaction_id].present?
        @transaction = Current.family.transactions.find(params[:transaction_id])
      end
    end

    def category_params
      params.require(:category).permit(:name, :color, :parent_id, :lucide_icon)
    end

    def category_merge_params
      params.permit(:target_id, source_ids: [])
    end

    def category_json(category)
      category.as_json(only: %i[id name color]).merge(
        html: render_to_string(
          partial: "DS/category_select/option",
          formats: [ :html ],
          locals: {
            category: category,
            selected: true,
            view_helpers: helpers
          }
        )
      )
    end

    def record_error_message(error)
      record = error.respond_to?(:record) ? error.record : nil
      record&.errors&.full_messages&.to_sentence.presence || error.message
    end
end
