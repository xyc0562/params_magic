module ParamsMagic
  module Utils

    class << self
      ##
      # V1::GoodEntriesController => V1::GoodEntry
      def base_name(klass, postfix='Controller')
        klass.name.sub(postfix, '').singularize
      end

      ##
      # V1::GoodEntriesController => Good entries controller
      def readable_name(klass)
        klass.name.demodulize.underscore.humanize
      end

      ##
      # V1::ApplicationController => application_id
      def id_name(klass, postfix='Controller')
        "#{instance_name(klass, postfix)}_id"
      end

      ##
      # V1::GoodEntriesController => good_entry
      def instance_name(klass, postfix='Controller')
        base_name(klass, postfix).demodulize.underscore
      end

      def true?(val)
        %w(true 1 t on).include? val.to_s.downcase
      end

      def add_associations(method, klass, *assocs)
        Class.new klass do
          self._associations = self._associations.dup
          assocs.each do |assoc|
            if assoc.class == Hash
              assoc_name = assoc[:assoc_name].to_s
              serializer = assoc[:serializer]
              # Hash means serializer is specified directly
            else
              assoc_name = assoc
              serializer = "#{assoc_name.to_s.singularize.classify}Serializer".constantize
              # Array means serializer will be deduced
            end
            send method, assoc_name, serializer: serializer
          end
        end
      end
    end

  end
end
