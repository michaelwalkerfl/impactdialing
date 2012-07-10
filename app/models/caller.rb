class Caller < ActiveRecord::Base
  include Rails.application.routes.url_helpers
  include Deletable
  validates_format_of :email, :allow_blank => true, :with => /^([^@\s]+)@((?:[-a-z0-9]+\.)+[a-z]{2,})$/i, :message => "Invalid email"
  belongs_to :campaign
  belongs_to :account
  has_many :caller_sessions
  has_many :caller_identities
  has_many :call_attempts
  has_many :answers
  before_create :create_uniq_pin
  validates_uniqueness_of :email, :allow_nil => true
  validates_presence_of :campaign_id

  scope :active, where(:active => true)
  
  delegate :subscription_allows_caller?, :to => :account
  delegate :activated?, :to => :account
  delegate :funds_available?, :to => :account

  cattr_reader :per_page
  @@per_page = 25
  
  def identity_name
    is_phones_only?  ? name : email
  end
  
  def create_uniq_pin
    uniq_pin=0
    while uniq_pin==0 do
      pin = rand.to_s[2..6]
      check = Caller.find_by_pin(pin) || CallerIdentity.find_by_pin(pin)
      uniq_pin=pin if check.blank?
    end
    self.pin = uniq_pin
  end
  
  

  
  def is_on_call?
    !caller_sessions.blank? && caller_sessions.on_call.size > 0
  end

  class << self
    include Rails.application.routes.url_helpers

    def ask_for_pin(attempt = 0)
      xml = if attempt > 2
              Twilio::Verb.new do |v|
                v.say "Incorrect Pin."
                v.hangup
              end
            else
              Twilio::Verb.new do |v|
                3.times do
                  v.gather(:numDigits => 5, :timeout => 10, :action => identify_caller_url(:host => Settings.host, :port => Settings.port, :attempt => attempt + 1), :method => "POST") do
                    v.say attempt == 0 ? "Please enter your pin." : "Incorrect Pin. Please enter your pin."
                  end
                end
              end
            end
      xml.response
    end
  end

  def self.hold
    Twilio::Verb.new { |v| v.play("#{APP_URL}/wav/hold.mp3"); v.redirect(hold_call_path(:host => Settings.host, :port => Settings.port), :method => "GET")}.response
  end

  def callin(campaign)    
    response = TwilioClient.instance.account.calls.create(
        :from =>APP_NUMBER,
        :to => Settings.phone,
        :url => receive_call_url(:host => Settings.host, :port => Settings.port)
    )
  end

  def phone
    #required for the form field.
  end

  def known_as
    return name unless name.blank?
    return email unless email.blank?
    ''
  end
  
  def info
    attributes.reject { |k, v| (k == "created_at") ||(k == "updated_at") }
  end
  
  
  def answered_call_stats(from, to, campaign)
    result = Hash.new
    question_ids = Answer.all(:select=>"distinct question_id", :conditions=>"campaign_id = #{campaign.id}")
    answer_count = Answer.select("possible_response_id").where("campaign_id = ? and caller_id = ?", campaign.id, self.id).within(from, to).group("possible_response_id").count
    total_answers = Answer.find_by_sql("SELECT COUNT(question_id) AS count_question_id, question_id AS question_id USE INDEX (index_answers_count_question_id) FROM answers  WHERE (campaign_id = #{campaign.id} and caller_id = #{self.id}) AND (created_at BETWEEN '#{from}' AND '#{to}') GROUP BY question_id")
    # total_answers = Answer.select("question_id").where("campaign_id = ? and caller_id = ?",campaign.id, self.id).within(from, to).group("question_id").count
    questions = Question.where("id in (?)",question_ids.collect{|q| q.question_id})
    questions.each do |question|        
      result[question.text] = question.possible_responses.collect { |possible_response| possible_response.stats(answer_count, total_answers) }
      result[question.text] << {answer: "[No response]", number: 0, percentage:  0} unless question.possible_responses.find_by_value("[No response]").present?
    end
    result
  end
  
  # def reassign_to_another_campaign(caller_session)
  #   return unless caller_session.attempt_in_progress.nil?
  #   if self.is_phones_only?
  #        if (caller_session.campaign.predictive_type != "preview" && caller_session.campaign.predictive_type != "progressive")
  #          Twilio.connect(TWILIO_ACCOUNT, TWILIO_AUTH)
  #          Twilio::Call.redirect(caller_session.sid, phones_only_caller_index_url(:host => Settings.host, :port => Settings.port, session_id: caller_session.id, :campaign_reassigned => true))
  #        end
  #      else
  #        caller_session.reassign_caller_session_to_campaign
  #        if campaign.predictive_type == Campaign::Type::PREVIEW || campaign.predictive_type == Campaign::Type::PROGRESSIVE
  #          caller_session.publish('conference_started', {}) 
  #        else
  #          caller_session.publish('caller_connected_dialer', {})
  #        end
  #      end
  # end
  
  
  def create_caller_session(session_key, sid, caller_type)
    if is_phones_only?
      caller_session = PhonesOnlyCallerSession.create(on_call: false, available_for_call: false, session_key: session_key, campaign: campaign , sid: sid, starttime: Time.now, caller_type: caller_type)
    else
      caller_session =  WebuiCallerSession.create(on_call: false, available_for_call: false, session_key: session_key, campaign: campaign , sid: sid, starttime: Time.now, caller_type: caller_type)
    end
    caller_sessions << caller_session
    caller_session
  end
  
  def create_caller_identity(session_key)
    caller_identities.create(session_key: session_key, pin: CallerIdentity.create_uniq_pin)    
  end
  

end
