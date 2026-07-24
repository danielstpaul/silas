Silas::Engine.routes.draw do
  namespace :channels do
    post "slack/events", to: "slack#events"
    post "slack/actions", to: "slack#actions"
    get "approvals/:token", to: "approvals#show", as: :approval
    post "approvals/:token", to: "approvals#update"
  end

  namespace :inbox do
    root to: "sessions#index"
    resources :sessions, only: %i[index show create] do
      resources :turns, only: :create
    end
    resources :turns, only: [] do
      member { post :cancel }
    end
    resources :invocations, only: [] do
      member do
        post :approve
        post :decline
      end
    end
  end
end
