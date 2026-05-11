class CategoriesController < ApplicationController
  MergeTargetNotFound = Class.new(StandardError)
  EmptyCategoryMerge = Class.new(StandardError)

  before_action :set_category, only: %i[edit update destroy]
  before_action :set_categories, only: %i[update edit]
  before_action :set_transaction, only: :create

  def index
    @categories = Current.family.categories.alphabetically

    render layout: "settings"
  end

  def new
    @category = Current.family.categories.new color: Category::COLORS.sample
    set_categories
  end

  def merge
    @categories = Current.family.categories.alphabetically

    render layout: "settings"
  end

  def create
    @category = Current.family.categories.new(category_params)

    if @category.save
      @transaction.update(category_id: @category.id) if @transaction

      flash[:notice] = t(".success")

      redirect_target_url = request.referer || categories_path
      respond_to do |format|
        format.html { redirect_back_or_to categories_path, notice: t(".success") }
        format.turbo_stream { render turbo_stream: turbo_stream.action(:redirect, redirect_target_url) }
      end
    else
      set_categories
      render :new, status: :unprocessable_entity
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
    redirect_back_or_to categories_path, notice: "All categories deleted"
  end

  def bootstrap
    Current.family.categories.bootstrap!

    redirect_back_or_to categories_path, notice: t(".success")
  end

  def perform_merge
    permitted_params = category_merge_params

    if conflicting_merge_target?(permitted_params)
      return redirect_to merge_categories_path, alert: t(".conflicting_target")
    end

    if target_selected_as_source?(permitted_params)
      return redirect_to merge_categories_path, alert: t(".target_selected_as_source")
    end

    sources = Current.family.categories.where(id: permitted_params[:source_ids])
    unless sources.any?
      return redirect_to merge_categories_path, alert: t(".invalid_categories")
    end

    merger = merge_categories!(permitted_params, sources)

    redirect_to categories_path, notice: t(".success", count: merger.merged_count)
  rescue MergeTargetNotFound
    redirect_to merge_categories_path, alert: t(".target_not_found")
  rescue EmptyCategoryMerge
    redirect_to merge_categories_path, alert: t(".no_categories_selected")
  rescue Category::Merger::UnauthorizedCategoryError => e
    redirect_to merge_categories_path, alert: e.message
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotDestroyed => e
    redirect_to merge_categories_path, alert: record_error_message(e)
  end

  private
    def set_category
      @category = Current.family.categories.find(params[:id])
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
      params.permit(:target_id, :new_target_name, :new_target_color, :new_target_icon, source_ids: [])
    end

    def conflicting_merge_target?(permitted_params)
      permitted_params[:target_id].present? && permitted_params[:new_target_name].present?
    end

    def target_selected_as_source?(permitted_params)
      permitted_params[:target_id].present? && Array(permitted_params[:source_ids]).include?(permitted_params[:target_id])
    end

    def merge_target_category(permitted_params)
      if permitted_params[:new_target_name].present?
        Current.family.categories.create!(
          name: permitted_params[:new_target_name],
          color: permitted_params[:new_target_color].presence || Category::COLORS.first,
          lucide_icon: permitted_params[:new_target_icon].presence || Category.suggested_icon(permitted_params[:new_target_name])
        )
      else
        Current.family.categories.find_by(id: permitted_params[:target_id])
      end
    end

    def merge_categories!(permitted_params, sources)
      Category.transaction do
        target = merge_target_category(permitted_params) || raise(MergeTargetNotFound)
        merger = Category::Merger.new(
          family: Current.family,
          target_category: target,
          source_categories: sources
        )

        raise EmptyCategoryMerge unless merger.merge!

        merger
      end
    end

    def record_error_message(error)
      record = error.respond_to?(:record) ? error.record : nil
      record&.errors&.full_messages&.to_sentence.presence || error.message
    end
end
