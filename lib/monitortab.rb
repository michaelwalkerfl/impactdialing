RAILS_ROOT = File.expand_path('../..', __FILE__)
require File.join(RAILS_ROOT, 'config/environment')

loop do
  begin
    monitors = Moderators.active
    monitors.each do |monitor|
      monitor.account.campaigns.each do |campaign|
        caller_sessions = CallerSession.on_call.on_campaign(campaign)
        caller_sessions.each do |caller_session|
          Moderator.publish_event(campaign, 'voter_event', {caller_session_id:  caller_session.id, campaign_id:  campaign.id, caller_id:  caller_session.caller.id, call_status: caller_session.attempt_in_progress.try(:status)})      
          Moderator.publish_event(campaign, 'update_dials_in_progress', {:campaign_id => campaign.id, :dials_in_progress => campaign.call_attempts.not_wrapped_up.size, :voters_remaining => Voter.remaining_voters_count_for('campaign_id', campaign.id)})            
        end
      end      
    end
    
  rescue Exception => e
  end
end