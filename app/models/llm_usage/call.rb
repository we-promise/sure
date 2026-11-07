# One AI call on the usage page: its requests (retries, JSON-mode resends) summed into one row,
# which opens to show each request.
class LlmUsage::Call
  attr_reader :requests

  # requests: the call's LlmUsage rows, oldest first.
  def initialize(requests)
    @requests = requests
  end

  def id = first.call_id || first.id
  def created_at = first.created_at
  def operation = first.operation
  def provider = last.provider
  def model = last.model

  # The last request decides: a call whose retry succeeded succeeded.
  def status = last.status
  def failed? = last.failed?
  def cancelled? = last.cancelled?

  def multiple_requests? = requests.size > 1
  def requests_count = requests.size

  def prompt_tokens = requests.sum(&:prompt_tokens)
  def completion_tokens = requests.sum(&:completion_tokens)
  def total_tokens = requests.sum(&:total_tokens)

  # nil when no request has a cost (self-hosted models, unknown prices).
  def estimated_cost
    costs = requests.filter_map(&:estimated_cost)
    costs.sum if costs.any?
  end

  def formatted_cost = estimated_cost.nil? ? "N/A" : "$#{estimated_cost.round(4)}"

  def error_message = failed_request&.error_message
  def http_status_code = failed_request&.http_status_code

  private
    def first = requests.first
    def last = requests.last
    def failed_request = requests.reverse.find(&:failed?)
end
