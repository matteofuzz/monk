module Monk
  module Storage
    module Backends
      # Local disk, the development and test default (file://storage/<env>)
      # and an explicit choice for one server with a persistent volume.
      # root is absolute, expanded at configure, so a worker Ractor never
      # depends on the current directory. secret signs the links of the
      # /_monk/storage routes (docs/adr/0018-storage-s3-compatible-direct-upload.md).
      File = Data.define(:root, :secret) do
        # Never print the secret -- a backend ends up in logs and exception
        # messages more easily than anyone intends (same as Mail's SMTP).
        def inspect
          "#<#{self.class.name} file://#{root}>"
        end
        alias_method :to_s, :inspect
      end
    end
  end
end
