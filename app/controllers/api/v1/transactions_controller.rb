# frozen_string_literal: true

class Api::V1::TransactionsController < Api::V1::BaseController
  include Pagy::Backend
  include Api::V1::TransactionLookup

  NATURES = %w[income expense inflow outflow].freeze
  INVALID_NATURE_MESSAGE = "nature must be one of: #{NATURES.join(", ")}".freeze
  # The index `type` filter, as Transaction::Search natures.
  TYPE_FILTER_NATURES = { "income" => "inflow", "expense" => "outflow" }.freeze

  # Ensure proper scope authorization for read vs write access
  before_action :ensure_read_scope, only: [ :index, :show ]
  before_action :ensure_write_scope, only: [ :create, :update, :destroy ]
  before_action :set_transaction, only: [ :show, :update, :destroy ]
  # Outside index's catch-all rescue so a bad filter is a 404/422, not a 500.
  before_action :set_search, only: :index
  before_action :ensure_write_permission, only: [ :update, :destroy ]

  def index
    transactions_query = @search.transactions_scope.includes(
      { entry: :account },
      :category, :merchant, :tags,
      transfer_as_outflow: { inflow_transaction: { entry: :account } },
      transfer_as_inflow: { outflow_transaction: { entry: :account } }
    ).reverse_chronological

    # Handle pagination with Pagy
    @pagy, @transactions = pagy(
      transactions_query,
      page: safe_page_param,
      limit: safe_per_page_param
    )

    # Make per_page available to the template
    @per_page = safe_per_page_param

    @split_parent_entry_ids = split_parent_entry_ids_for(@transactions)

    # Rails will automatically use app/views/api/v1/transactions/index.json.jbuilder
    render :index

  rescue => e
    Rails.logger.error "TransactionsController#index error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    render json: {
      error: "internal_server_error",
      message: "An unexpected error occurred"
    }, status: :internal_server_error
  end

  def show
    # Rails will automatically use app/views/api/v1/transactions/show.json.jbuilder
    render :show

  rescue => e
    Rails.logger.error "TransactionsController#show error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    render json: {
      error: "internal_server_error",
      message: "An unexpected error occurred"
    }, status: :internal_server_error
  end

  def create
    family = current_resource_owner.family

    # Validate account_id is present
    unless account_id_param.present?
      render json: {
        error: "validation_failed",
        message: "Account ID is required",
        errors: [ "Account ID is required" ]
      }, status: :unprocessable_entity
      return
    end

    if idempotency_source_param.present? && idempotency_external_id.blank?
      render json: {
        error: "validation_failed",
        message: "Source requires external_id",
        errors: [ "Source requires external_id" ]
      }, status: :unprocessable_entity
      return
    end

    account = family.accounts.writable_by(current_resource_owner).find(account_id_param)

    if idempotency_key_requested? && (existing_entry = existing_idempotent_entry(account))
      return render_existing_idempotent_entry(existing_entry)
    end

    return render_validation_error(INVALID_NATURE_MESSAGE) if invalid_nature?
    return render_validation_error("tag_ids must be an array of tag ids") if malformed_tag_ids?
    return render_validation_error("Unknown tag id") if unknown_tag_ids?
    return render_validation_error("Unknown category id") if unknown_category_id?
    return render_validation_error("Unknown merchant id") if unknown_merchant_id?

    @entry = account.entries.new(entry_params_for_create)

    if @entry.save
      @entry.lock_saved_attributes!
      @entry.transaction.lock_attr!(:tag_ids) if @entry.transaction.tags.any?
      @entry.mark_user_modified! if user_modified_requested?
      @entry.sync_account_later
      @entry.apply_immediate_rules_later

      @transaction = @entry.transaction
      render :show, status: :created
    else
      render json: {
        error: "validation_failed",
        message: "Transaction could not be created",
        errors: @entry.errors.full_messages
      }, status: :unprocessable_entity
    end

  rescue ActiveRecord::RecordNotUnique
    if idempotency_key_requested? && account && (existing_entry = existing_idempotent_entry(account))
      render_existing_idempotent_entry(existing_entry)
    else
      raise
    end
  rescue => e
    Rails.logger.error "TransactionsController#create error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    render json: {
      error: "internal_server_error",
      message: "An unexpected error occurred"
    }, status: :internal_server_error
  end

  def update
    if @entry.split_child?
      render json: { error: "validation_failed", message: "Split child transactions cannot be edited directly. Use the split editor." }, status: :unprocessable_entity
      return
    end

    if @entry.split_parent? && split_financial_fields_changed?
      render json: { error: "validation_failed", message: "Split parent amount, date, and type cannot be changed directly. Use the split editor." }, status: :unprocessable_entity
      return
    end

    return render_validation_error(INVALID_NATURE_MESSAGE) if invalid_nature?
    # The web UI hides amount and nature on a transfer: one leg alone cannot
    # change them without breaking Transfer#transfer_has_opposite_amounts.
    if @entry.transaction.transfer && transfer_amount_changed?
      return render_validation_error("A transfer's amount and nature cannot be changed through one of its transactions")
    end
    return render_validation_error("tag_ids must be an array of tag ids") if malformed_tag_ids?
    return render_validation_error("Unknown tag id") if tags_provided? && unknown_tag_ids?
    return render_validation_error("Unknown category id") if unknown_category_id?
    return render_validation_error("Unknown merchant id") if unknown_merchant_id?

    rule_input = @entry.rule_input_snapshot
    updated = false

    Entry.transaction do
      if @entry.update(entry_params_for_update)
        sync_needed = @entry.saved_changes_affect_balances?

        # Handle tags separately - only when explicitly provided in the request
        # This allows clearing tags with tag_ids: [] while preserving tags when not specified
        if tags_provided?
          @entry.transaction.tag_ids = requested_tag_ids
          @entry.transaction.save!
          @entry.transaction.lock_attr!(:tag_ids) if @entry.transaction.tags.any?
        end

        @entry.sync_account_later if sync_needed
        @entry.lock_saved_attributes!
        @entry.mark_user_modified! if user_modified_requested?

        @transaction = @entry.transaction
        updated = true
        render :show
      else
        render json: {
          error: "validation_failed",
          message: "Transaction could not be updated",
          errors: @entry.errors.full_messages
        }, status: :unprocessable_entity
        raise ActiveRecord::Rollback
      end
    end

    # After the commit, so the enqueue runs here and not in a deferred
    # after-commit callback once the response is already rendered.
    @entry.apply_immediate_rules_later(changed_from: rule_input) if updated

  rescue => e
    Rails.logger.error "TransactionsController#update error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    render json: {
      error: "internal_server_error",
      message: "An unexpected error occurred"
    }, status: :internal_server_error
  end

  def destroy
    if @entry.split_child?
      render json: { error: "validation_failed", message: "Split child transactions cannot be deleted individually." }, status: :unprocessable_entity
      return
    end

    @entry.destroy_unless_split_part_transferred!
    @entry.sync_account_later

    render json: {
      message: "Transaction deleted successfully"
    }, status: :ok

  rescue Entry::SplitPartTransferredError
    render json: { error: "validation_failed", message: "A part of this split is linked as a transfer. Remove that transfer before you delete the transaction." }, status: :unprocessable_entity
  rescue => e
    Rails.logger.error "TransactionsController#destroy error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    render json: {
      error: "internal_server_error",
      message: "An unexpected error occurred"
    }, status: :internal_server_error
  end

  private

    def set_transaction
      load_accessible_transaction(params[:id])
    end

    # Reading needs access to the account. Deleting, or changing anything
    # outside the annotate fields, needs the write tier (AccountPolicy#update?);
    # a member in the annotate tier may only change the AccountShare annotate
    # fields (notes, category, merchant, tags), the same split the web UI
    # applies in TransactionsController#permitted_entry_params. A refused request is a 403,
    # not a silently trimmed update, so the client learns nothing was applied.
    def ensure_write_permission
      level = action_name == "update" && annotate_only_update? ? :annotate : :write

      require_api_account_permission!(@entry.account, level, resource: "transaction")
    end

    # Judged on the permitted params, not raw params: keys outside
    # transaction_params are ignored on update for every role (account_id
    # included), so they cannot widen what an annotate-tier member changes.
    def annotate_only_update?
      transaction_params.except(
        *AccountShare::ANNOTATE_ENTRY_ATTRIBUTES, *AccountShare::ANNOTATE_TRANSACTION_ATTRIBUTES
      ).empty?
    end

    def accessible_account_ids
      current_resource_owner.family.accounts
        .accessible_by(current_resource_owner)
        .where.not(status: "pending_deletion")
        .select(:id)
    end

    # Parses the index filters into Transaction::Search, the query the web
    # list runs. The API keeps every account the caller can read, disabled ones
    # included, and also searches merchant names.
    def set_search
      account_ids = intersected_ids_filter(:account_id, :account_ids)

      @search = Transaction::Search.new(
        current_resource_owner.family,
        filters: {
          account_ids:,
          category_ids: intersected_ids_filter(:category_id, :category_ids),
          merchant_ids: intersected_ids_filter(:merchant_id, :merchant_ids),
          tag_ids: uuid_list_filter_param(:tag_ids),
          start_date: date_filter_param(:start_date),
          end_date: date_filter_param(:end_date),
          min_amount: decimal_filter_param(:min_amount),
          max_amount: decimal_filter_param(:max_amount),
          nature: TYPE_FILTER_NATURES[enum_filter_param(:type, TYPE_FILTER_NATURES.keys)],
          search: string_filter_param(:search),
          excluded: boolean_filter_param(:excluded),
          exclude_split_parents: boolean_filter_param(:exclude_split_parents) == true,
          search_merchant_names: true,
          active_accounts_only: false
        },
        # Transaction::Search reads an empty account_ids as no filter, as the
        # web form sends it, so account_id and account_ids that share no
        # account narrow the accessible ones to none instead.
        accessible_account_ids: account_ids == [] ? [] : accessible_account_ids,
        budget: requested_budget
      )
    end

    # A single id and its list (account_id and account_ids...) match their
    # intersection. UUIDs compare in any case.
    def intersected_ids_filter(single_key, list_key)
      [ uuid_filter_param(single_key), uuid_list_filter_param(list_key) ]
        .compact.map { |ids| Array(ids).map(&:downcase) }.reduce(:&)
    end

    # Same visibility as GET /api/v1/budgets/:id: the household budget, the
    # caller's own, or one its owner shared with the caller. Its rows stay
    # within the caller's accessible accounts: a budget share does not share
    # the owner's accounts.
    def requested_budget
      budget_id = uuid_filter_param(:budget_id)
      return if budget_id.nil?

      budget = current_resource_owner.family.budgets.find_by(id: budget_id)
      raise ActiveRecord::RecordNotFound, "Budget not found" unless budget&.viewable_by?(current_resource_owner)

      budget.current_user = current_resource_owner
      budget
    end

    def ensure_write_scope
      authorize_scope!(:write)
    end

    def transaction_params
      params.require(:transaction).permit(
        :date, :amount, :name, :description, :notes, :currency,
        :category_id, :merchant_id, :nature, :user_modified, tag_ids: []
      )
    end

    # An API client can opt a transaction it creates or updates into the
    # same sync-protection a manual edit gets (Entry#protected_from_sync?) -
    # useful for a client that owns its own writes into an account also
    # linked to a bank-sync provider (Plaid/SimpleFin/etc.), so the next
    # sync only links its external_id to the entry instead of overwriting
    # the category/name the client already set.
    def user_modified_requested?
      ActiveModel::Type::Boolean.new.cast(transaction_params[:user_modified])
    end

    def account_id_param
      params.dig(:transaction, :account_id).presence
    end

    def entry_params_for_create
      entry_params = {
        name: transaction_params[:name] || transaction_params[:description],
        date: transaction_params[:date],
        amount: calculate_signed_amount,
        currency: transaction_params[:currency] || current_resource_owner.family.currency,
        notes: transaction_params[:notes],
        entryable_type: "Transaction",
        entryable_attributes: {
          category_id: transaction_params[:category_id],
          merchant_id: transaction_params[:merchant_id],
          tag_ids: requested_tag_ids
        }
      }
      if idempotency_key_requested?
        entry_params[:external_id] = idempotency_external_id
        entry_params[:source] = idempotency_source
      end

      entry_params.compact
    end

    def entry_params_for_update
      entry_params = {
        name: transaction_params[:name] || transaction_params[:description],
        date: transaction_params[:date],
        notes: transaction_params[:notes],
        entryable_attributes: {
          id: @entry.entryable_id,
          category_id: transaction_params[:category_id],
          merchant_id: transaction_params[:merchant_id]
          # Note: tag_ids handled separately in update action to distinguish
          # "not provided" from "explicitly set to empty"
        }.compact_blank
      }

      # A nature without an amount applies to the stored amount.
      if transaction_params[:amount].present?
        entry_params[:amount] = calculate_signed_amount
      elsif transaction_params[:nature].present?
        entry_params[:amount] = calculate_signed_amount(@entry.amount)
      end

      entry_params.compact
    end

    # Check if tag_ids was explicitly provided in the request.
    # This distinguishes between "user wants to update tags" vs "user didn't specify tags".
    def tags_provided?
      params[:transaction].key?(:tag_ids)
    end

    # Strong parameters drops a tag_ids of any other shape, which would read as
    # "no tags" and clear them on update.
    def malformed_tag_ids?
      tag_ids = params.require(:transaction)[:tag_ids]
      !(tag_ids.nil? || (tag_ids.is_a?(Array) && tag_ids.all?(String)))
    end

    # Tags belong to a family: ids are resolved through the caller's own, so
    # another family's tag is refused like one that does not exist.
    # An id that is not a UUID casts to nil and is unknown. It has to be refused
    # here: with only such ids the list is [nil], and the collection writer
    # would drop the nil and clear every tag.
    def unknown_tag_ids?
      ids = requested_tag_ids
      return true if ids.include?(nil)

      ids.any? && current_resource_owner.family.tags.where(id: ids).count != ids.size
    end

    # A client re-sends the ids it read back, so the category or merchant a
    # transaction already holds is not refused: no new link is made.
    def unknown_category_id?
      raw = transaction_params[:category_id].presence
      return false if raw.nil?

      id = canonical_uuid(raw)
      return true if id.nil?
      return false if id == @entry&.transaction&.category_id

      !current_resource_owner.family.categories.exists?(id: id)
    end

    # The family's own merchants, and provider merchants the caller can reach.
    # A family merchant on a reachable transaction isn't enough: it may be
    # another family's, linked before this check.
    def unknown_merchant_id?
      raw = transaction_params[:merchant_id].presence
      return false if raw.nil?

      id = canonical_uuid(raw)
      return true if id.nil?
      return false if id == @entry&.transaction&.merchant_id

      family = current_resource_owner.family
      !family.merchants.exists?(id: id) &&
        !family.available_merchants_for(current_resource_owner).where(type: "ProviderMerchant").exists?(id: id)
    end

    # The lowercase hyphenated form Postgres stores, so an id resent in another
    # case still matches the one a transaction holds. Nil for a non-UUID.
    def canonical_uuid(value)
      Category.type_for_attribute(:id).cast(value)
    end

    # The request's tag ids in canonical UUID form, each once. Postgres matches
    # a UUID in any case, so one tag spelled two ways is one tag, and writing
    # the raw list would store it twice.
    def requested_tag_ids
      @requested_tag_ids ||= Array(transaction_params[:tag_ids]).compact_blank
        .map { |id| Tag.type_for_attribute(:id).cast(id) }
        .uniq
    end

    def split_financial_fields_changed?
      params.dig(:transaction, :amount).present? ||
        params.dig(:transaction, :date).present? ||
        params.dig(:transaction, :nature).present?
    end

    def idempotency_key_requested?
      idempotency_external_id.present?
    end

    def idempotency_external_id
      idempotency_param_value(:external_id)
    end

    def idempotency_source
      idempotency_source_param.presence || "api"
    end

    def idempotency_source_param
      idempotency_param_value(:source)
    end

    def idempotency_param_value(key)
      value = params.dig(:transaction, key)
      value.to_s.presence if value.is_a?(String) || value.is_a?(Numeric)
    end

    def existing_idempotent_entry(account)
      account.entries.find_by(
        external_id: idempotency_external_id,
        source: idempotency_source
      )
    end

    def render_existing_idempotent_entry(entry)
      unless entry.entryable.is_a?(Transaction)
        render json: {
          error: "validation_failed",
          message: "External ID already exists for a non-transaction entry",
          errors: [ "External ID already exists for a non-transaction entry" ]
        }, status: :unprocessable_entity
        return
      end

      @entry = entry
      @transaction = entry.transaction
      render :show, status: :ok
    end

    def invalid_nature?
      nature = transaction_params[:nature]
      nature.present? && NATURES.exclude?(nature.to_s.downcase)
    end

    def transfer_amount_changed?
      amount = entry_params_for_update[:amount]
      amount.present? && amount.to_d != @entry.amount
    end

    def calculate_signed_amount(amount = transaction_params[:amount].to_f)
      nature = transaction_params[:nature]

      case nature.to_s.downcase
      when "income", "inflow"
        -amount.abs  # Income is negative
      when "expense", "outflow"
        amount.abs   # Expense is positive
      else
        amount       # Use as provided
      end
    end
end
