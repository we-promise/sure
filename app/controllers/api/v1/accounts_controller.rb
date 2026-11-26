# frozen_string_literal: true

class Api::V1::AccountsController < Api::V1::BaseController
  include Pagy::Backend

  InvalidParam = Class.new(StandardError)
  private_constant :InvalidParam

  # The account's own fields; the rest of a request goes in accountable_attributes.
  ACCOUNT_FIELDS = %i[
    name balance currency subtype opening_balance_date
    institution_name institution_domain notes exclude_from_reports
  ].freeze

  # Fields of the web forms that mean nothing when an account is created. An
  # id is ignored; the others are refused, so they are not accepted and then
  # dropped.
  UPDATE_ONLY_FIELDS = %i[id rate_schedule_snapshot purchase_date initial_balance_shown].freeze

  # Types of fields that are not attributes of the model.
  FIELD_TYPES = {
    opening_balance_date: ActiveModel::Type::Date.new,
    effective_date: ActiveModel::Type::Date.new, # a row of rate_changes
    rate: ActiveModel::Type::Decimal.new(precision: 9, scale: 6) # the model limits it to 0..Loan::MAX_INTEREST_RATE
  }.freeze

  # Free text columns that the models only understand a few values of.
  ALLOWED_VALUES = {
    rate_type: [ Loan::FIXED_RATE_TYPE, *Loan::VARIABLE_RATE_TYPES ].freeze,
    area_unit: %w[sqft sqm].freeze,
    mileage_unit: %w[mi km].freeze
  }.freeze
  private_constant :ALLOWED_VALUES

  BOOLEAN_VALUES = {
    true => true, "true" => true, "t" => true, "1" => true, 1 => true,
    false => false, "false" => false, "f" => false, "0" => false, 0 => false
  }.freeze
  private_constant :BOOLEAN_VALUES

  # Ruby also reads "1_000" as 1000, so the shape is checked before converting.
  # An exponent has at most 4 digits: a longer one can underflow to 0 or ask
  # for a number with millions of digits.
  NUMBER_FORMAT = /\A[+-]?(\d+(\.\d+)?|\.\d+)([eE][+-]?\d{1,4})?\z/
  private_constant :NUMBER_FORMAT

  MAX_INTEGER = 2**31 # integer columns are 4 bytes
  private_constant :MAX_INTEGER

  # Precision and scale of a decimal that has no column of its own, such as a
  # vehicle's initial_balance: it ends up in an entry amount.
  AMOUNT_PRECISION = [ 19, 4 ].freeze
  private_constant :AMOUNT_PRECISION

  MAX_LIST_ROWS = 1_000 # a variable rate loan has one rate_changes row per reset
  private_constant :MAX_LIST_ROWS

  before_action :ensure_read_scope, only: [ :index, :show ]
  before_action :ensure_write_scope, only: :create
  before_action :reject_guest_writes!, only: :create

  def index
    @per_page = safe_per_page_param

    @pagy, @accounts = pagy(
      accounts_scope.alphabetically,
      page: safe_page_param,
      limit: @per_page
    )

    render :index
  rescue => e
    Rails.logger.error "AccountsController#index error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    render json: {
      error: "internal_server_error",
      message: "An unexpected error occurred"
    }, status: :internal_server_error
  end

  def show
    unless valid_uuid?(params[:id])
      render json: {
        error: "not_found",
        message: "Account not found"
      }, status: :not_found
      return
    end

    @account = accounts_scope.find(params[:id])

    render :show
  rescue ActiveRecord::RecordNotFound
    render json: {
      error: "not_found",
      message: "Account not found"
    }, status: :not_found
  rescue => e
    Rails.logger.error "AccountsController#show error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    render json: {
      error: "internal_server_error",
      message: "An unexpected error occurred"
    }, status: :internal_server_error
  end

  def create
    # Missing is null, "" or {} (Rails wraps an empty JSON body as {}); anything
    # else that is not an object, an empty array included, is the wrong type.
    account = params[:account]
    raise ActionController::ParameterMissing, :account if omitted?(account) || (account.is_a?(ActionController::Parameters) && account.empty?)
    raise InvalidParam, "account must be an object" unless account.is_a?(ActionController::Parameters)

    accountable_class = requested_accountable_class(account)
    raise InvalidParam, "accountable_type must be one of: #{Accountable::TYPES.map(&:underscore).join(', ')}" unless accountable_class

    attributes = account_create_params(account, accountable_class)
    raise InvalidParam, "name and balance are required" unless attributes[:name] && attributes[:balance]

    family = current_resource_owner.family
    opening_balance_date = opening_balance_date_for(attributes.delete(:opening_balance_date))
    attributes[:currency] = supported_currency(attributes[:currency], family)
    reject_unknown_subtype!(accountable_class, attributes)
    reject_overwritten_loan_balance!(attributes, opening_balance_date)
    reject_unused_rate_changes!(attributes)
    lock_supplied_attributes!(accountable_class, attributes)

    @account = family.accounts.create_and_sync(
      attributes.merge(accountable_type: accountable_class.name, owner: current_resource_owner),
      opening_balance_date: opening_balance_date,
      skip_initial_sync: true
    )
    schedule_initial_sync(@account)

    render :show, status: :created
  rescue ActionController::ParameterMissing, ActiveRecord::RecordNotFound
    raise # the base controller answers these with 400 and 404
  rescue InvalidParam, ArgumentError => e
    render_validation_error(e.message)
  rescue ActiveRecord::RecordInvalid => e
    render_validation_error(e.record.errors.full_messages.to_sentence)
  rescue ActiveRecord::RangeError, ActiveModel::RangeError
    render_validation_error("a number is out of range")
  rescue => e
    Rails.logger.error "AccountsController#create error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    render json: {
      error: "internal_server_error",
      message: "An unexpected error occurred"
    }, status: :internal_server_error
  end

  private

    def ensure_read_scope
      authorize_scope!(:read)
    end

    def ensure_write_scope
      authorize_scope!(:write)
    end

    # Accepts "Loan" or "loan" / "credit_card" / "CreditCard".
    def requested_accountable_class(account)
      requested = account[:accountable_type]
      Accountable.from_type(requested.underscore.camelize) if requested.is_a?(String)
    end

    # Every field is read as exactly the shape its column takes, before
    # anything else sees it. `permit` would drop an array or object from a
    # scalar field without a word and ActiveRecord would turn false into 0,
    # true into "t" and a bad date into nil, so those requests would be
    # saved as something the client never sent. Null and "" mean "not sent".
    #
    # Accountable fields come from the same lists the web forms use, so the
    # API cannot set anything the UI cannot.
    def account_create_params(account, accountable_class)
      attributes = typed_attributes(Account, account, ACCOUNT_FIELDS)

      details = account[:accountable_attributes]
      return attributes if omitted?(details)
      raise InvalidParam, "accountable_attributes must be an object" unless details.is_a?(ActionController::Parameters)

      update_only = (UPDATE_ONLY_FIELDS - [ :id ]).reject { |field| details[field].to_s.strip.empty? }
      raise InvalidParam, "#{update_only.join(', ')} can only be set when updating an account" if update_only.any?

      permitted = "#{accountable_class.name.pluralize}Controller".constantize.permitted_accountable_attributes
      fields, lists = permitted.reject { |field| UPDATE_ONLY_FIELDS.include?(field) }.partition { |field| field.is_a?(Symbol) }
      attributes[:accountable_attributes] = typed_attributes(accountable_class, details, fields).merge(object_lists(details, lists))
      attributes
    end

    # null and "" both mean the field was not sent.
    def omitted?(raw)
      raw.nil? || (raw.is_a?(String) && raw.strip.empty?)
    end

    def typed_attributes(model, raw, names)
      names.each_with_object({}) do |name, typed|
        type = FIELD_TYPES.fetch(name) { model.type_for_attribute(name.to_s) }
        value = typed_value(name, raw[name], type)
        typed[name] = value unless value.nil?
      end
    end

    def typed_value(name, raw, type)
      return if omitted?(raw)

      case type.type
      when :integer, :decimal, :float then parse_number(name, raw, type)
      when :boolean then BOOLEAN_VALUES.fetch(raw.is_a?(String) ? raw.strip.downcase : raw) { raise InvalidParam, "#{name} must be true or false" }
      when :date then parse_date(raw) || raise(InvalidParam, "#{name} must be an ISO 8601 date (YYYY-MM-DD)")
      when :uuid then (raw.is_a?(String) && valid_uuid?(raw)) ? raw : raise(InvalidParam, "#{name} must be a UUID")
      when :string, :text, nil then text_value(name, raw)
      else raise InvalidParam, "#{name} cannot be set through the API"
      end
    end

    def text_value(name, raw)
      raise InvalidParam, "#{name} must be a string" unless raw.is_a?(String)

      allowed = ALLOWED_VALUES[name]
      raise InvalidParam, "#{name} must be one of: #{allowed.join(', ')}" if allowed && !allowed.include?(raw)

      raw
    end

    # A whole number or a finite decimal that fits the column exactly: a value
    # with more decimal places than the column keeps is refused, not rounded.
    def parse_number(name, raw, type)
      raise InvalidParam, "#{name} must be a number" unless raw.is_a?(String) || raw.is_a?(Numeric)

      raise InvalidParam, "#{name} has more digits than a JSON number can carry; send it as a string" if rounded_float?(raw)

      integer = type.type == :integer
      precision, scale = type.precision ? [ type.precision, type.scale.to_i ] : AMOUNT_PRECISION
      limit = integer ? MAX_INTEGER : 10**(precision - scale)
      text = raw.to_s.strip
      value = parse_decimal(text) if text.match?(NUMBER_FORMAT)

      in_range = value && (integer ? value.between?(-limit, limit - 1) : value.abs < limit)
      raise InvalidParam, "#{name} must be a #{'whole ' if integer}number below #{limit}" unless in_range && (!integer || value.frac.zero?)
      raise InvalidParam, "#{name} can have at most #{scale} decimal places" if !integer && value != value.round(scale)

      integer ? value.to_i : value
    end

    # A JSON number is read as a Float, which holds about 15 digits exactly.
    # A longer one has already been rounded by the time it gets here.
    def rounded_float?(raw)
      raw.is_a?(Float) && raw.to_s.sub(/e.*/i, "").delete("-.").sub(/\A0+/, "").length > 15
    end

    # Lists of objects such as a loan's rate_changes. Every row needs all of
    # its fields and nothing else; the model checks the rates are in range.
    def object_lists(details, lists)
      lists.reduce({}, :merge).each_with_object({}) do |(name, fields), result|
        rows = details[name]
        next if omitted?(rows)
        raise InvalidParam, "#{name} must be a list of objects" unless rows.is_a?(Array) && rows.all?(ActionController::Parameters)
        raise InvalidParam, "#{name} can have at most #{MAX_LIST_ROWS} rows" if rows.size > MAX_LIST_ROWS

        result[name] = rows.map do |row|
          raise InvalidParam, "each #{name} row can only have #{fields.join(' and ')}" if (row.keys.map(&:to_sym) - fields).any?

          fields.index_with do |field|
            typed_value("#{name}.#{field}", row[field], FIELD_TYPES.fetch(field)) || raise(InvalidParam, "each #{name} row needs #{fields.join(' and ')}")
          end
        end
        # The model keeps one row per date, so a repeated one would be lost.
        raise InvalidParam, "#{name} has two rows with the same #{fields.first}" if result[name].uniq { |row| row[fields.first] }.size != rows.size
      end
    end

    def opening_balance_date_for(date)
      return Time.zone.today - 2.years unless date
      raise InvalidParam, "opening_balance_date cannot be in the future" if date > Date.current

      date
    end

    def supported_currency(code, family)
      currency = code ? Family.normalize_currency_code(code) : family.currency
      currency || raise(InvalidParam, "currency must be a supported ISO 4217 code")
    end

    # A subtype can arrive on the account and again inside accountable_attributes,
    # and the second one wins when the record is built, so both are checked and
    # they must agree.
    def reject_unknown_subtype!(accountable_class, attributes)
      subtypes = [ attributes[:subtype], attributes.dig(:accountable_attributes, :subtype) ].compact.uniq
      return if subtypes.empty?

      raise InvalidParam, "subtype cannot be set on #{accountable_class.name.underscore} accounts" if accountable_class::SUBTYPES.empty?
      raise InvalidParam, "subtype was sent twice with different values" if subtypes.many?
      return if accountable_class::SUBTYPES.key?(subtypes.first)

      raise InvalidParam, "subtype must be one of: #{accountable_class::SUBTYPES.keys.join(', ')}"
    end

    # The account is already committed, so a queue that is down must not turn
    # this into a failed create (a retry would make a second account). The
    # regular syncs pick the account up.
    def schedule_initial_sync(account)
      account.sync_later
    rescue StandardError => e
      Rails.logger.error "AccountsController#create could not schedule the first sync of account #{account.id}: #{e.class}: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}"
      Sentry.capture_exception(e) if defined?(Sentry)
      DebugLogEntry.capture(
        category: "api",
        level: "error",
        message: "Could not schedule the first sync of an account created through the API: #{e.class}",
        source: self.class.name,
        account: account,
        family: account.family,
        metadata: { error_class: e.class.name } # the message can carry a connection URL; the log and Sentry have it
      )
    end

    # A schedule on a fixed rate loan would be stored and never used.
    def reject_unused_rate_changes!(attributes)
      details = attributes[:accountable_attributes] || {}
      return if details[:rate_changes].blank? || Loan::VARIABLE_RATE_TYPES.include?(details[:rate_type])

      raise InvalidParam, "rate_changes only apply when rate_type is #{Loan::VARIABLE_RATE_TYPES.join(' or ')}"
    end

    # create_and_sync saves the records again after creating them, so there
    # are no saved changes left for lock_saved_attributes! to lock. The fields
    # the client sent are locked as the accountable is inserted instead, so a
    # later provider refresh (an AVM re-reading a property's area, say) keeps
    # them.
    def lock_supplied_attributes!(accountable_class, attributes)
      supplied = attributes[:accountable_attributes].to_h.keys.map(&:to_s)
      supplied << "subtype" if attributes[:subtype] # Account#subtype= stores it on the accountable
      names = supplied.uniq & accountable_class.column_names
      return if names.empty?

      attributes[:accountable_attributes] ||= {}
      attributes[:accountable_attributes][:locked_attributes] = names.index_with { Time.current }
    end

    # Account.create_and_sync anchors an opening balance on the loan's
    # start_date (else the opening balance date) and, when that is today,
    # cannot also anchor the entered balance, so the initial sync would
    # replace it with initial_balance. Reject the conflict instead of
    # answering 201 with a balance that is about to change.
    def reject_overwritten_loan_balance!(attributes, opening_balance_date)
      details = attributes[:accountable_attributes] || {}
      return unless details[:initial_balance] && details[:initial_balance] != attributes[:balance]

      start_date = details[:start_date]
      anchor_date = start_date && start_date > Entry.min_supported_date ? start_date : opening_balance_date
      return unless anchor_date == Date.current

      raise InvalidParam,
            "balance must equal initial_balance when the opening date is today: " \
            "the opening balance wins on its own date, so a different balance would be discarded"
    end

    def accounts_scope
      scope = current_resource_owner.family.accounts
                                    .accessible_by(current_resource_owner)
                                    .includes(:accountable, account_providers: :provider)
      include_disabled_accounts? ? scope : scope.visible
    end

    def include_disabled_accounts?
      ActiveModel::Type::Boolean.new.cast(params[:include_disabled])
    end
end
