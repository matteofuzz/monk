require_relative "generator"

# Monk's own modules, one generator each (docs/adr/0017), in dependency
# order only for readability: the registry resolves dependencies itself.
%w[base postgres redis mail auth jobs websocket live].each do |name|
  require_relative "generators/#{name}"
end
