module Monk
  class AuthNotConfiguredError < StandardError
  end

  class InvalidRedirectError < StandardError
  end

  class MissingAuthConfigError < StandardError
  end

  class InvalidAuthConfigError < StandardError
  end

  class MissingAuthDeliveryError < StandardError
  end

  # Monk::Auth.clear_login_requests! outside MONK_ENV=test: it would lift
  # the login-email rate limit for every address.
  class ClearLoginRequestsOutsideTestsError < StandardError
  end
end
