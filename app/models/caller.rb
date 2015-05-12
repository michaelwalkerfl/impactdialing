##
# @on_call:: boolean field; returns true when caller is dialed in
# @available_for_call:: boolean field; returns true when caller can take another call
#
class Caller < ActiveRecord::Base
  include Rails.application.routes.url_helpers
  include Deletable
  include SidekiqEvents
  validates_format_of :username, :with => /\A[^ ]*\Z/, :message => "cannot contain blank space.",  :if => lambda {|s| !s.is_phones_only  }
  validates_presence_of :username,  :if => lambda {|s| !s.is_phones_only  }
  validates_presence_of :name,  :if => lambda {|s| s.is_phones_only }
  validates_uniqueness_of :username, :scope => :campaign_id, :if => lambda {|s| !s.is_phones_only and s.campaign_id.present? }, :message => 'another caller with that username is assigned to this campaign already'
  validates_presence_of :campaign, :if => lambda {|s| s.campaign_id.present?}, :message => 'invalid campaign'
  belongs_to :campaign
  belongs_to :account
  belongs_to :caller_group
  has_many :caller_sessions
  has_many :caller_identities
  has_many :call_attempts
  has_many :answers

  before_create :create_uniq_pin
  before_validation :assign_to_caller_group_campaign
  before_validation { |caller| caller.username = username.downcase unless username.nil?}
  before_save :reassign_caller_campaign

  validate :check_subscription_for_caller_groups
  validate :campaign_and_caller_on_same_account

  scope :active, -> { where(:active => true) }

  delegate :subscription_allows_caller?, :to => :account
  delegate :funds_available?, :to => :account
  delegate :as_time_zone, :to=> :campaign

  cattr_reader :per_page
  @@per_page = 25

private
  def campaign_and_caller_on_same_account
    return true if campaign_id.nil? or campaign.nil? # campaigns may be auto-archived
                                                     # in which case callers become orphaned
                                                     # until reassigned to another campaign

    unless self.account_id == campaign.account_id
      errors.add(:campaign, 'invalid campaign')
    end
  end

  def assign_to_caller_group_campaign
    if caller_group_id_changed? && !caller_group_id.nil?
      self.campaign_id = CallerGroup.find(caller_group_id).campaign_id
    end
  end

  def restored_caller_has_campaign
    if active_change == [false, true] && !campaign.active
      errors.add(:base, 'The campaign this caller was assigned to has been deleted. Please assign the caller to a new campaign.')
    end
  end

public
  def identity_name
    is_phones_only? ? name : username
  end

  def ability
    @ability ||= Ability.new(account)
  end

  def check_subscription_for_caller_groups
    return true if caller_group_id.blank?

    unless ability.can? :manage, CallerGroup
      errors.add(:base, 'Your subscription does not allow managing caller groups.')
    end
  end

  def reassign_caller_campaign
    if campaign_id_changed?
      caller_sessions.on_call.each {|caller_session| caller_session.reassign_to_another_campaign(self.campaign_id) }
    end
  end

  def create_uniq_pin
    self.pin = CallerIdentity.create_uniq_pin
  end

  def is_on_call?
    !caller_sessions.blank? && caller_sessions.on_call.size > 1
  end

  class << self
    include Rails.application.routes.url_helpers

    def ask_for_pin(attempt = 0, provider)
      xml = if attempt > 2
              Twilio::Verb.new do |v|
                v.say "Incorrect pin."
                v.hangup
              end
            else
              Twilio::Verb.new do |v|
                3.times do
                  v.gather(:finishOnKey => '*', :timeout => 10, :action => identify_caller_url(:host => DataCentre.call_back_host_from_provider(provider), :port => Settings.twilio_callback_port, :protocol => "http://", :attempt => attempt + 1), :method => "POST") do
                    v.say attempt == 0 ? "Please enter your pin and then press star." : "Incorrect pin. Please enter your pin and then press star."
                  end
                end
              end
            end
      xml.response
    end
  end

  def phone
    #required for the form field.
  end

  def known_as
    return name unless name.blank?
    return username unless username.blank?
    ''
  end

  def info
    attributes.reject { |k, v| (k == "created_at") ||(k == "updated_at") }
  end


  def answered_call_stats(from, to, campaign)
    result = Hash.new
    question_ids = Answer.where(campaign_id: campaign.id).uniq.pluck(:question_id)
    answer_count = Answer.select(:possible_response_id).
      where(:campaign_id => campaign.id, :caller_id => self.id).
      within(from, to).group("possible_response_id").count
    total_answers = Answer.select(:question_id).
      where(:campaign_id => campaign.id, :caller_id => self.id).
      within(from, to).group("question_id").count
    questions = Question.where(id: question_ids)
    questions.each do |question|
      result[question.text] = question.possible_responses.order('possible_response_order').collect { |possible_response| possible_response.stats(answer_count, total_answers) }
      result[question.text] << {answer: "[No response]", number: 0, percentage:  0} unless question.possible_responses.find_by_value("[No response]").present?
    end
    result
  end

  def create_caller_session(session_key, sid, caller_type)
    if is_phones_only?
      caller_session = PhonesOnlyCallerSession.create(session_key: session_key, campaign: campaign , sid: sid, starttime: Time.now, caller_type: caller_type, state: 'initial', caller: self, on_call: true, script_id: campaign.script_id)
    else
      caller_session =  WebuiCallerSession.create(on_call: false, available_for_call: false, session_key: session_key, campaign: campaign , sid: sid, starttime: Time.now, caller_type: caller_type, state: 'initial', caller: self, on_call: true, script_id: campaign.script_id)
    end
    caller_session
  end

  def started_calling(session)
    RedisPredictiveCampaign.add(campaign.id, campaign.type)
    RedisStatus.set_state_changed_time(campaign.id, "On hold", session.id)
  end

  def calling_voter_preview_power(session, voter_id)
    enqueue_call_flow(CallerPusherJob, [session.id, "publish_calling_voter"])
    enqueue_call_flow(PreviewPowerDialJob, [session.id, voter_id])
  end
  deprecate :calling_voter_preview_power

  def create_caller_identity(session_key)
    caller_identities.create(session_key: session_key, pin: CallerIdentity.create_uniq_pin)
  end
end

# ## Schema Information
#
# Table name: `callers`
#
# ### Columns
#
# Name                   | Type               | Attributes
# ---------------------- | ------------------ | ---------------------------
# **`id`**               | `integer`          | `not null, primary key`
# **`name`**             | `string(255)`      |
# **`username`**         | `string(255)`      |
# **`pin`**              | `string(255)`      |
# **`account_id`**       | `integer`          |
# **`active`**           | `boolean`          | `default(TRUE)`
# **`created_at`**       | `datetime`         |
# **`updated_at`**       | `datetime`         |
# **`password`**         | `string(255)`      |
# **`is_phones_only`**   | `boolean`          | `default(FALSE)`
# **`campaign_id`**      | `integer`          |
# **`caller_group_id`**  | `integer`          |
#
