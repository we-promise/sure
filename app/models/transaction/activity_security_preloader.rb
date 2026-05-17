class Transaction::ActivitySecurityPreloader
  def initialize(records)
    @records = Array(records)
  end

  def preload
    transactions.each do |transaction|
      transaction.set_preloaded_activity_security(securities_by_id[transaction.activity_security_id.to_s])
    end

    records
  end

  private
    attr_reader :records

    def transactions
      @transactions ||= records.filter_map do |record|
        case record
        when Transaction
          record
        when Entry
          record.transaction? ? record.entryable : nil
        end
      end
    end

    def securities_by_id
      @securities_by_id ||= begin
        security_ids = transactions.filter_map(&:activity_security_id).uniq
        return {} if security_ids.empty?

        Security.where(id: security_ids).index_by { |security| security.id.to_s }
      end
    end
end
