ImpactDialing::Application.routes.draw do
  root :to => "home#index"

  ['monitor', 'how_were_different', 'pricing', 'contact', 'policies'].each do |path|
    match "/#{path}", :to => "home##{path}", :as => path
  end
  match '/client/policies', :to => 'client#policies', :as => :client_policies
  match '/broadcast/policies', :to => 'broadcast#policies', :as => :broadcast_policies
  match '/homecss/css/style.css', :to => 'home#homecss'

  namespace 'admin' do
    [:campaigns, :scripts, :callers].each do |entities|
      resources entities, :only => [:index] do
        put '/restore', :controller => entities, :action => 'restore', :as => 'restore'
      end
    end
  end

  namespace "callers" do
    resources :campaigns
  end


  resources :caller do
    member do
      post :callin
      post :ready
    end
    collection { get :login }
  end

  #broadcast
  scope 'broadcast' do
    resources :campaigns do
      member do
        post :verify_callerid
        post :start
        post :stop
        get :dial_statistics
      end
      collection do
        get :control
        get :running_status
      end
      resources :voter_lists, :except => [:new, :show] do
        collection { post :import }
      end
    end
    resources :reports do
      collection do
        get :usage
        get :dial_details
      end
    end
    get '/deleted_campaigns', :to => 'campaigns#deleted', :as => :broadcast_deleted_campaigns
    resources :scripts
    match 'monitor', :to => 'monitor#index'

    match '/', :to => 'broadcast#index', :as => 'broadcast_root'
    match '/login', :to => 'broadcast#login', :as => 'broadcast_login'
  end

  namespace 'client' do
    match 'campaign_new', :to => 'client#campaign_new', :as => 'campaign_new'
    match 'campaign_view/:id', :to => 'client#campaign_view', :as => 'campaign_view'

    ['campaigns', 'scripts', 'callers'].each do |type_plural|
      get "/deleted_#{type_plural}", :to => "#{type_plural}#deleted", :as => "deleted_#{type_plural}"
      get "/#{type_plural}", :to => "client#type_plural", :as => "#{type_plural}"
      resources type_plural, :only => [] do
        put 'restore', :to => "#{type_plural}#restore"
      end
    end
  end

  scope 'client' do
    match '/', :to => 'client#index', :as => 'client_root'
    resources :campaigns, :only => [] do
      member { post :verify_callerid }
      resources :voter_lists, :except => [:new, :show], :name_prefix => 'client' do
        collection { post :import }
      end
    end
  end

  scope 'caller' do
    match '/', :to => 'caller#index', :as => 'caller_root'
  end

  resources :call_attempts, :only => [:create, :update] do
    member { post :connect }
  end

  resources :users do
    put '/update_password', :to => 'client/users#update_password', :as => 'update_password'
  end
  get '/reset_password', :to => 'client/users#reset_password', :as => 'reset_password'

  match '/client/login', :to => 'client#login', :as => :login
  match '/caller/login', :to => 'caller#login', :as => :caller_login

  match '/client/reports', :to => 'client#reports', :as => 'report'
  match '/client/reports/usage', :to => 'client/reports#usage', :as => 'report_usage'
  match '/twilio_callback', :to => 'twilio#callback', :as => :twilio_callback
  match '/twilio_report_error', :to => 'twilio#report_error', :as => :twilio_report_error
  match '/twilio_call_ended', :to => 'twilio#call_ended', :as => :twilio_call_ended

  match ':controller/:action/:id'
  match ':controller/:action'
end
