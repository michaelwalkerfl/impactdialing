require 'rails_helper'

describe 'CalculateDialsJob' do
  include FakeCallData

  def make_abandon_rate_acceptable(campaign)
    create_list(:bare_call_attempt, 10, :completed, {
      campaign: campaign
    })
    create_list(:bare_call_attempt, 1, :abandoned, {
      campaign: campaign
    })
  end
  def campaign_is_calculating_dials!(campaign)
    campaign.set_calculate_dialing
    expect(campaign.calculate_dialing?).to be_truthy
  end

  let(:admin) do
    create(:user)
  end
  let(:campaign) do
    create_campaign_with_script(:bare_predictive, admin.account).last
  end

  describe '.perform(campaign_id)' do
    let(:dial_queue) do
      CallFlow::DialQueue.new(campaign)
    end

    before do
      add_voters(campaign, :voter, 25)
      add_callers(campaign, 5)
    end

    after do
      Resque.remove_queue :dialer_worker
    end

    shared_examples 'all calculate dial jobs' do
      it 'removes "dial_calculate:#{campaign_id}" key from Redis, such that Predictive#calculate_dialing? returns false (flag exists to help prevent queueing multiple CalculateDialsJob from DialerLoop)' do
        campaign_is_calculating_dials!(campaign)

        CalculateDialsJob.perform(campaign.id)

        expect(campaign.calculate_dialing?).to be_falsy
      end
    end

    context 'campaign is not fit to dial' do
      it 'does not calculate how many dials should be attempted' do
        expect(campaign).to_not receive(:numbers_to_dial)
        expect(Campaign).to receive(:find).with(campaign.id){ campaign }
        CalculateDialsJob.perform(campaign.id)
      end

      context 'abort available callers' do
        before do
          expect(campaign).to receive(:abort_available_callers_with).with(:dialing_prohibited)
        end
        it 'account not funded' do
          campaign.account.quota.update_attributes!(minutes_allowed: 0)
          expect(CalculateDialsJob.fit_to_dial?(campaign)).to be_falsey
        end

        it 'outside calling hours' do
          now    = Time.now
          anchor = now.hour % 12 == 0 ? 10 : now.hour
          campaign.update_attributes(start_time: Time.new(2015, 1, 1, anchor - 2), end_time: Time.new(2015, 1, 1, anchor - 1))
          expect(CalculateDialsJob.fit_to_dial?(campaign)).to be_falsey
        end

        it 'calling disabled' do
          campaign.account.quota.update_attributes!(disable_calling: true)
          expect(CalculateDialsJob.fit_to_dial?(campaign)).to be_falsey
        end
      end
    end


    context 'one or more dials will be made' do
      before do
        campaign.callers.each do |caller|
          create(:bare_caller_session, :available, :webui, {
            campaign: campaign, caller: caller
          })
        end
      end

      it 'queues DialerJob w/ campaign_id & list of phone numbers to dial (one number per caller)' do
        phone_numbers = Voter.order('id').limit(campaign.callers.count).map(&:household).map(&:phone)
        CalculateDialsJob.perform(campaign.id)

        dialer_job = {'class' => 'DialerJob', 'args' => [campaign.id, phone_numbers]}

        expect(resque_jobs(:dialer_worker)).to(include(dialer_job))
      end

      it_behaves_like 'all calculate dial jobs'
    end

    context 'no dials will be made' do
      before do
        campaign.callers.each do |caller|
          create(:bare_caller_session, :not_available, :webui, {
            campaign: campaign, caller: caller
          })
        end
      end
      context 'calculated voters to dial is zero or less' do
        before do
          available_caller_session = create(:bare_caller_session, :available, :webui, {
            campaign: campaign, caller: campaign.callers.first
          })
          campaign.number_presented(1)
          make_abandon_rate_acceptable(campaign)
          Resque.redis.del "queue:dialer_worker"
          Resque.redis.del "queue:call_flow"
        end

        it_behaves_like 'all calculate dial jobs'

        it 'returns early' do
          CalculateDialsJob.perform(campaign.id)
          resque_actual = Resque.peek :dialer_worker
          resque_expected = nil
          sidekiq_actual = Sidekiq::Queue.new 'call_flow'
          sidekiq_expected = 0

          expect(resque_actual).to eq resque_expected
          expect(sidekiq_actual.size).to eq sidekiq_expected
        end
      end

      context 'no voters returned from load attempt' do
        before do
          CallerSession.delete_all
          create_list(:bare_caller_session, 5, :available, :webui, {
            campaign: campaign, caller: campaign.callers.first
          })
          create_list(:bare_caller_session, 5, :not_available, :webui, {
            campaign: campaign, caller: campaign.callers.first
          })

          dial_queue = CallFlow::DialQueue.new(campaign)
          dial_queue_pop_n_reliably(dial_queue, Voter.count)
        end

        it_behaves_like 'all calculate dial jobs'

        it 'queues CampaignOutOfNumbersJob for all on_call callers' do
          expect(campaign.caller_sessions.on_call.count).to eq 10
          expect(CallFlow::DialQueue.new(campaign).size(:available)).to be_zero

          CalculateDialsJob.perform(campaign.id)

          actual = Sidekiq::Queue.new :call_flow

          expect(actual.size).to eq 10

          actual.each do |job|
            expect(job['class']).to eq 'CampaignOutOfNumbersJob'
          end
        end

        context 'no voters returned from load attempt but voters still in available set' do
          let(:voters) do
            create_list(:voter, 2, campaign: campaign)
          end
          let(:dial_queue) do
            CallFlow::DialQueue.new(campaign)
          end
          before do
            dial_queue.cache_all(voters)
            # bypass initial check
            allow(CalculateDialsJob).to receive(:fit_to_dial?){ true }
            allow(campaign).to receive(:ringing_count){ 5 }
            allow(campaign).to receive(:presented_count){ 5 }
            allow(Campaign).to receive(:find){ campaign }
          end

          it 'does not queue CampaignOutOfNumbersJob' do
            expect(dial_queue.available.size).to eq 2
            CalculateDialsJob.perform(campaign.id)
            queue = Sidekiq::Queue.new :call_flow
            expect(queue.size).to be_zero
          end
        end
      end
    end

    context 'exceptions do occur' do
      before do
        allow(campaign).to receive(:number_of_voters_to_dial).and_raise("Crazyestness")
      end

      it 'handle w/ intelligence'
      
      it_behaves_like 'all calculate dial jobs'
    end
  end
end
