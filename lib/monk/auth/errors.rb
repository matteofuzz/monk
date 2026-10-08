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
end
