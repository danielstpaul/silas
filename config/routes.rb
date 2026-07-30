Silas::Engine.routes.draw do
  # The mounted MCP endpoint (Streamable HTTP, stateless mode: POST only).
  post "mcp", to: "mcp#handle"

  namespace :api do
    namespace :v1 do
      resources :sessions, only: %i[create show] do
        resources :turns, only: :create
        resources :approvals, only: :index
        get :stream, on: :member, to: "streams#show"
      end
      resources :turns, only: [] do
        member { post :cancel }
      end
      resources :approvals, only: [] do
        member do
          post :approve
          post :decline
          post :answer
        end
      end
    end
  end

  namespace :channels do
    post "slack/events", to: "slack#events"
    post "slack/actions", to: "slack#actions"
    get "approvals/:token", to: "approvals#show", as: :approval
    post "approvals/:token", to: "approvals#update"
  end

  namespace :inbox do
    root to: "sessions#index"
    get "held", to: "held#index"
    resources :staff, only: %i[index show], param: :name, constraints: { name: %r{[^/]+} }
    resources :sessions, only: %i[index show create] do
      resources :turns, only: :create
    end
    resources :turns, only: [] do
      member do
        post :cancel
        post :raise_budget
      end
    end
    resources :invocations, only: [] do
      member do
        post :approve
        post :decline
        post :answer
      end
    end
  end
end
