module Monk
  class AuthNotConfiguredError < StandardError
  end

  class InvalidRedirectError < StandardError
  end

  class MissingAuthConfigError < StandardError
  end
end
