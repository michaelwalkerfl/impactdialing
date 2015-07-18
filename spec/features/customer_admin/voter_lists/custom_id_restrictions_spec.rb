require 'rails_helper'

describe 'Upload', js: true, type: :feature do
  def upload_list(file)
    attach_file 'upload_datafile', Rails.root.join('spec/fixtures/files/' + file)
  end

  let(:user){ create(:user) }
  let(:account){ user.account }
  let(:campaign) do
    create(:predictive, {
      account: account
    })
  end

  before do
    web_login_as(user)
  end

  context 'first voter list' do
    before do
      visit edit_client_campaign_path(campaign)
      upload_list('valid_voters_list_redis.csv')
    end

    it 'can map custom id' do
      expect(page).to have_css('option[value="custom_id"]')
      select 'ID', from: 'ID'
    end
  end

  context 'subsequent voter lists' do
    context 'when first voter list mapped custom id' do
      before do
        create(:voter_list, {
          campaign: campaign,
          csv_to_system_map: {
            custom_id: 'ID',
            phone: 'Phone'
          }
        })
      end

      it 'can map custom id' do
        visit edit_client_campaign_path(campaign)
        upload_list('valid_voters_list_redis.csv')
        expect(page).to have_css('option[value="custom_id"]')
        select 'ID', from: 'ID'
      end
    end

    context 'when first voter list did not map custom id' do
      before do
        create(:voter_list, {
          campaign: campaign,
          csv_to_system_map: {
            phone: 'Phone'
          }
        })
      end

      it 'cannot map custom id' do
        visit edit_client_campaign_path(campaign)
        upload_list('valid_voters_list_redis.csv')
        expect(page).to have_css('#csv_to_system_map_phone')
        expect(page).to_not have_css('option[value="custom_id"]')
      end
    end
  end
end