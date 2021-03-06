require 'active_record'
require "ostruct"
require 'yaml'
require 'logger'
require 'fileutils'

RAILS_ROOT = File.expand_path('../..', __FILE__)
require File.join(RAILS_ROOT, 'config/environment')
SIMULATOR_ROOT = ENV['SIMULATOR_ROOT'] || File.expand_path('..', __FILE__)
FileUtils.mkdir_p(File.join(SIMULATOR_ROOT, 'log'), :verbose => true)
ActiveRecord::Base.logger = Logger.new(File.open(File.join(SIMULATOR_ROOT, 'log', "simulator_#{RAILS_ENV}.log"), 'a'))

#def database_settings
#  yaml_file = File.open(File.join(File.dirname(__FILE__), '../config/database.yml'))
#  yaml = YAML.load(yaml_file)
#  @plugins ||= yaml[RAILS_ENV].tap{|y| ActiveRecord::Base.logger.info y}
#end
#
#ActiveRecord::Base.establish_connection(
#  :adapter  => database_settings['adapter'],
#  :database => database_settings['database'],
#  :username => database_settings['username'],
#  :password => database_settings['password'].blank? ? nil : database_settings['password'],
#  :host     => database_settings['host']
#)

class CallerSession < ActiveRecord::Base
end

class CallAttempt < ActiveRecord::Base
  def duration
    return nil unless call_start
    ((wrapup_time || Time.now) - self.call_start).to_i
  end

  def ringing_duration
    return 15 unless connecttime
    (connecttime - created_at).to_i
  end
end

class SimulatedValues < ActiveRecord::Base
end

class CallerStatus
  attr_accessor :status

  def initialize(status)
    @status = status
  end

  def available?
    @status == 'available'
  end

  def unavailable?
    !available?
  end

  def toggle
    @status = available? ? 'busy' : 'available'
  end
end

def average(array)
  array.sum.to_f / array.size
end

def simulator_campaign_base_values(campaign_id, start_time)
  caller_statuses = CallerSession.where(:campaign_id => campaign_id,
            :on_call => true).size.times.map{ CallerStatus.new('available') }            
  campaign = Campaign.find(campaign_id)
  
  call_attempts_from_start_time = campaign.call_attempts.between((Time.now - start_time.seconds), Time.now)
  observed_conversations = call_attempts_from_start_time.where(:status => "Call completed with success.").map{|attempt| OpenStruct.new(:length => attempt.duration_wrapped_up, :counter => 0)}
  observed_dials = call_attempts_from_start_time.map{|attempt| OpenStruct.new(:length => attempt.ringing_duration, :counter => 0, :answered? => attempt.status == 'Call completed with success.') }
  ActiveRecord::Base.logger.info observed_conversations
  
  unless observed_conversations.blank?
    mean_conversation = average(observed_conversations.map(&:length))
    longest_conversation = observed_conversations.max_by{|conv| conv.length}.try(:length)
  else
    mean_conversation = 0
    longest_conversation = 0
  end

  expected_conversation = mean_conversation
  best_conversation = longest_conversation
  
  puts "Expected Conversation: #{expected_conversation}"
  puts "Longest Conversation: #{longest_conversation}"    
  puts "Available Callers: #{caller_statuses.length}"
  puts "Observed Conversations: #{observed_conversations.length}"
  puts "Observed Dials: #{observed_dials.length}"
  puts "Answered Observed Dials: #{observed_dials.count(&:answered?)}"
  
  [expected_conversation, mean_conversation, longest_conversation, best_conversation, caller_statuses, observed_conversations, observed_dials]
  
end

def simulate(campaign_id)
  target_abandonment = Campaign.find(campaign_id).acceptable_abandon_rate
  start_time = 60 * 10
  simulator_length = 60 * 60
  abandon_count = 0
  
  dials_needed = 1
  best_dials = 1  
  best_utilization = 0
  expected_conversation, mean_conversation, longest_conversation, best_conversation, caller_statuses, observed_conversations, observed_dials =  simulator_campaign_base_values(campaign_id, start_time)
  
  while expected_conversation < longest_conversation   
    idle_time = active_time = 0.0 
    t = 0
    active_dials =  []
    finished_dials = []
    active_conversations = []
    finished_conversations = []
    
    while(t <= simulator_length)  
      
                      
      active_conversations.clone.each do |call_attempt|
        if call_attempt.counter == call_attempt.length
          caller_statuses.detect(&:unavailable?).toggle
          finished_conversations << call_attempt
          active_conversations.delete(call_attempt)
          call_attempt.counter = 0
        else
          call_attempt.counter += 1
        end
      end
          
      active_dials.clone.each do |dial|
        if dial.counter == dial.length
          if dial.answered?
            if status = caller_statuses.detect(&:available?)
              status.toggle
              active_conversations << observed_conversations[rand(observed_conversations.size)]
            else
              abandon_count += 1
            end
          end
          finished_dials << dial
          active_dials.delete(dial)
          dial.counter = 0
        else
          dial.counter += 1
        end
      end
     
      available_callers = caller_statuses.count(&:available?) + 
                        active_conversations.count{|active_conversation| (active_conversation.counter > expected_conversation) && (active_conversation.counter < longest_conversation)}                        
      
      ringing_lines = active_dials.length
      dials_to_make = (( dials_needed * available_callers ) - ringing_lines).to_i
      dials_to_make.times{ active_dials << observed_dials[rand(observed_dials.size)] }
      idle_time += caller_statuses.select(&:available?).size
      active_time += caller_statuses.select(&:unavailable?).size
      finished_dials.each{|dial| dial.counter += 1}
      finished_conversations.each{|call_attempt| call_attempt.counter += 1}
      t += 1     
      
      puts "Number of Available Caller: #{available_callers}"                        
      puts "Number of Active Dials: #{ringing_lines}"
      puts "Dials to make: #{dials_to_make}"
   end
   
   finished_conversations_answered_count = finished_conversations.count(&:answered?)
   simulated_abandonment = abandon_count / (finished_conversations_answered_count == 0 ? 1 : finished_conversations_answered_count)
   if simulated_abandonment <= target_abandonment
     
     utilization = active_time / ( active_time + idle_time )     
     if utilization > best_utilization
       best_dials = dials_needed
       best_utilisation = utilisation
       best_conversation = expected_conversation
     end
   end
   increment = 10.0

   answer_ratio =  observed_dials.size  / observed_dials.count(&:answered?)
   puts "Dials Needed: #{dials_needed}"
   puts "Answer ratio: #{answer_ratio}"
   if dials_needed < answer_ratio

     dials_needed += (answer_ratio - 1)/ increment
   else
     dials_needed = 1
     expected_conversation += ((longest_conversation - mean_conversation) /increment)
   end
   
   puts "Dials Needed: #{dials_needed}"
   puts "Expected Conversations Time: #{expected_conversation}"
  end  
  puts "Best Dials: #{best_dials}"
  puts "Best Conversation: #{best_conversation}"
  puts "Longest Conversation: #{longest_conversation}"
  SimulatedValues.find_or_create_by_campaign_id(campaign_id).update_attributes(best_dials: best_dials, best_conversation: best_conversation, longest_conversation: longest_conversation)
end

loop do
  begin
    logged_in_campaigns = ActiveRecord::Base.connection.execute("select distinct campaign_id from caller_sessions where on_call=1")
    logged_in_campaigns.each do |k|     
      puts "Simulating #{k.first}"
      campaign = Campaign.find(k.first)      
      simulate(k.first) if campaign.type == Campaign::Type::PREDICTIVE
    end
    sleep 3
  rescue Exception => e
    if e.class == SystemExit || e.class == Interrupt
      ActiveRecord::Base.logger.info "============ EXITING  ============"
      exit
    end
    ActiveRecord::Base.logger.info "Rescued - #{ e } (#{ e.class })!"
    ActiveRecord::Base.logger.info e.backtrace
  end
end
