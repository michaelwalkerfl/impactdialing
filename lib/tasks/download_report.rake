desc "Update twilio call data"


task :download_report => :environment do
  report = get_report
  AWS::S3::Base.establish_connection!(
      :access_key_id => 'AKIAJCTCEHXW27SMQRHA',
      :secret_access_key => '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'
  )

  filename = "#{Rails.root}/temp/report_#{@campaign.name}.csv"
  File.open(filename, "w"){|f| f.write report}
  AWS::S3::S3Object.store("report_#{@campaign.name}.csv", File.open(filename), "download_reports", :content_type => "text/csv")
end

def get_report
  c = Campaign.find(@campaign_id)
  @campaign = c
  custom_fields = c.account.custom_voter_fields.collect { |field| field.name }
  campaign_notes = c.script.notes.collect { |note| note.note }
  campaign_questions = c.script.questions.collect { |q| q.text }

  report = CSV.generate do |csv|
    csv << [Voter.upload_fields, custom_fields, "Caller", "Status", "Call start", "Call end", "Attempts", "Recording", campaign_questions, campaign_notes].flatten
    c.all_voters.each do |v|
      voter_fields = v.selected_fields(Voter.upload_fields)
      voter_custom_fields = v.selected_custom_fields(custom_fields)

      last_call_attempt = v.last_call_attempt
      call_details = [last_call_attempt ? last_call_attempt.caller.try(:email) : '', v.status, last_call_attempt ? last_call_attempt.call_start.try(:in_time_zone, c.time_zone) : '', last_call_attempt ? last_call_attempt.call_end.try(:in_time_zone, c.time_zone) : '', v.call_attempts.size, last_call_attempt ? last_call_attempt.report_recording_url : ''].flatten
      notes, answers = [], []
      if last_call_attempt
        c.script.questions.each { |q| answers << v.answers.for(q).first.try(:possible_response).try(:value) }
        c.script.notes.each { |note| notes << v.note_responses.for(note).last.try(:response) }
        csv << [voter_fields, voter_custom_fields, call_details, answers, notes].flatten
      else
        csv << [voter_fields, voter_custom_fields, nil, "Not Dialed"].flatten
      end
    end
  end
  return report
end