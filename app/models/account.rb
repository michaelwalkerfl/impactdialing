class Account < ActiveRecord::Base
  
  has_many :users
  has_many :campaigns, :conditions => {:active => true}
  has_many :all_campaigns, :class_name => 'Campaign'
  has_many :recordings
  has_many :custom_voter_fields
  has_one :billing_account
  has_many :scripts
  has_many :callers
  has_many :voter_lists
  has_many :voters
  has_many :families
  has_many :blocked_numbers
  has_many :moderators
  has_many :payments
  
  module Subscription_Type
    MANUAL = "Manual"
    PER_MINUTE = "Per Minute"
    PER_CALLER = "Per Caller"    
  end
  
  def current_balance
    self.payments.where("amount_remaining>0").inject(0) do |sum, payment|
      sum + payment.amount_remaining
    end
  end
  
  def update_caller_password(password)
    hash_caller_password(password)
    self.save
  end
  
  def hash_caller_password(password)
    self.caller_hashed_password_salt = ActiveSupport::SecureRandom.base64(8)
    self.caller_password = Digest::SHA2.hexdigest(caller_hashed_password_salt + password)    
  end
  
  def self.authenticate_caller?(pin, password)
    return false unless password
    caller = Caller.find_by_pin(pin)
    return nil if caller.nil?
    account = caller.account
    if account.caller_password == Digest::SHA2.hexdigest(account.caller_hashed_password_salt + password)
      caller
    else
      nil
    end
  end
  
  
  
  def trial?
    self.payments.count==1 && self.payments.first.notes=="Trial credit" && recurly_subscription_uuid.nil?
  end
  
  def callers_in_progress
    CallerSession.where("campaign_id in (?) and on_call=1", self.campaigns.map {|c| c.id})
  end

  def cancel_subscription
    return if self.recurly_subscription_uuid.blank?
    subscription = Recurly::Subscription.find(self.recurly_subscription_uuid)
    subscription.cancel
    sync_subscription
  end
  
  def sync_subscription
    #pull latest subscription data from recurly
    
    recurly_account = Recurly::Account.find(self.recurly_account_code)
    has_active_subscriptions=false
    recurly_account.subscriptions.find_each do |subscription|
      if subscription.state=="active"
        has_active_subscriptions=true
        self.subscription_count=subscription.quantity
        self.recurly_subscription_uuid=subscription.uuid
        self.subscription_active=subscription.state=="active" ? true : false
        self.subscription_name=subscription.plan.name
        self.activated=true
        self.card_verified=true
        self.save
      end
    end
    if !has_active_subscriptions
      self.recurly_subscription_uuid=nil
      self.subscription_count=0
      self.subscription_active=false
      self.subscription_name=nil
      self.save
    end
  end
  
  def subscription_allows_caller?
    if self.trial? || per_minute_subscription? || manual_subscription?
      return true
    elsif per_caller_subscription? && self.callers_in_progress.length <= self.subscription_count
      return true
    else
      return false
    end
  end
  
  def per_minute_subscription?
    subscription_name == Subscription_Type::PER_MINUTE
  end
  
  def manual_subscription?
    subscription_name == Subscription_Type::MANUAL
  end
  
  def per_caller_subscription?
    subscription_name == Subscription_Type::PER_CALLER
  end

  def funds_available?
    (per_caller_subscription? || manual_subscription?) ? true : current_balance>0
  end
      
  def create_recurly_account_code
    return self.recurly_account_code if !self.recurly_account_code.nil?
    begin
      user = User.where("account_id=?",self.id).order("id asc").first
      account = Recurly::Account.create(
        :account_code => self.id,
        :email        => user.email,
        :first_name   => user.fname,
        :last_name    => user.lname,
        :company_name => user.orgname
      )
      self.recurly_account_code=account.account_code
      self.save
      self.recurly_account_code
    rescue
      nil
    end
  end
  
  def set_recurly_subscription(new_subscription_name)
    self.create_recurly_account_code
    self.sync_subscription
    self.cancel_subscription if self.subscription_name!=new_subscription_name
    self.create_recurly_subscription(new_subscription_name)
  end
  
  def create_recurly_subscription(plan_code)

     subscription = Recurly::Subscription.create(
      :plan_code => plan_code, 
      :account   => {
         :account_code => self.recurly_account_code
      	}
    )
    
    self.sync_subscription
  end
  
  def is_manual?
    subscription_name=="Manual"
  end
  
  def active_subscription
    # default to per minute if not defined
    if subscription_name!="Per Minute" && subscription_active
      return subscription_name
    else
      return "Per Minute"
    end
  end

  def new_billing_account
    BillingAccount.create(:account => self)
  end

  def paid?
    Rails.logger.debug('Deprecated! Call #activated? instead.')
    Rails.logger.debug("Called from #{caller[1]}")
    activated?
  end
  
  def toggle_call_recording!
    self.record_calls = !self.record_calls
    self.save
  end

  def custom_fields
    custom_voter_fields
  end
  
  def create_chargify_customer_id
    return self.chargify_customer_id if !self.chargify_customer_id.nil?
    user = User.find_by_account_id(self.id)
    customer = Chargify::Customer.create(
      :first_name   => user.fname,
      :last_name    => user.lname,
      :email        => user.email,
      :organization => user.orgname
    )
    self.chargify_customer_id=customer.id
    self.save
    self.chargify_customer_id
  end
  

  def check_autorecharge(amount_remaining)
    if autorecharge_enabled? && autorecharge_trigger >= amount_remaining
      begin
        if status != 'autorecharge_pending'
          update_attribute(:status, 'autorecharge_pending')
          new_payment = Payment.charge_recurly_account(self, self.autorecharge_amount, "Auto-recharge")
          if new_payment.nil?
             flash_now(:error, "There was a problem charging your credit card.  Please try updating your billing information or contact support for help.")
          end
          update_attribute(:status, '')
          return new_payment
       end
      rescue ActiveRecord::StaleObjectError
        # pretty much do nothing
      end
      
    end
  end
  
  def variable_abandonment?
    abandonment == 'variable'
  end
  
  def abandonment_value
    if variable_abandonment?
      "Variable"
    else
      "Fixed"
    end
  end
  
end
