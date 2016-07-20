module Authenticable
  include ActionController::HttpAuthentication::Token

  def current_user
    authentication_token = params[:authentication] || request.env["HTTP_AUTHENTICATION"]
    @current_user ||= User.find_by(auth_token: authentication_token)
  end

  def authenticate_with_token!
    render json: {errors: "Not authenticated"},
      status: :unauthorized unless user_signed_in?
  end

  def user_signed_in?
    current_user.present?
  end
end
