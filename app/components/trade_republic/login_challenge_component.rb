# What a started phone number and PIN login waits for: the push approval in
# the Trade Republic app or the authenticator code. Shared by a connection
# logging in again and a new connection's pending login.
class TradeRepublic::LoginChallengeComponent < ApplicationComponent
  include TradeRepublic::PanelTranslatable

  def initialize(record:, login_stage:)
    @record = record
    @login_stage = login_stage
  end

  attr_reader :record, :login_stage

  def render?
    login_stage.in?(%w[authenticator_code waiting_for_approval])
  end

  def login_path(action)
    helpers.polymorphic_path([ action, record ], login_token: record.login_token)
  end
end
