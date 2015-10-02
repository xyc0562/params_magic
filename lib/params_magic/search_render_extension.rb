module ParamsMagic
  module SearchRenderExtension
    protected
    ##
    # Render an array of entities
    def render_jsons(entries, serializer=nil, root='entries', modify_serializer=true, page=nil)
      serializer ||= "#{ParamsMagic::Utils.base_name(self.class)}Serializer".demodulize.constantize
      if entries.present? && modify_serializer
        serializer = modify_assocs serializer, entries[0]
      end
      if root
        meta = { count: entries.respond_to?(:total_count) ? entries.total_count : entries.size,
                 page: (page || params[:page]).to_i }
        meta[:pageCount] = entries.total_pages if entries.respond_to? :total_pages
        render json: entries, each_serializer: serializer, root: root, meta: meta
      else
        render json: entries, each_serializer: serializer, root: root
      end
    end

    ##
    # Render a single entity
    def render_json(entry=nil, serializer=nil, modify_serializer=true)
      serializer ||= "#{ParamsMagic::Utils.base_name(self.class)}Serializer".demodulize.constantize
      entry ||= instance_variable_get "@#{ParamsMagic::Utils.instance_name(self.class)}"
      serializer = modify_assocs serializer, entry if modify_serializer
      render json: entry, serializer: serializer, root: nil
    end

    ##
    # Building nested serializer based on associations passed in from the request
    def modify_assocs(serializer, entry)
      @_associations ||= {}
      ones = @_associations[:ones] || {}
      manies = @_associations[:manies] || {}
      # Start from root entry's class
      _build_serializer serializer, entry.class, @_serializers || {}, ones, manies
    end

    def _build_serializer(current_serializer, record_class, serializer_map, ones, manies)
      # For each has_one entry's class, recursively add to serializer passed_in
      ones.each do |k,v|
        current_serializer = _build_serializer_step current_serializer, k, v, :has_one, record_class, serializer_map
      end
      # Do the same for has_many
      manies.each do |k,v|
        current_serializer = _build_serializer_step current_serializer, k, v, :has_many, record_class, serializer_map
      end
      current_serializer
    end

    ##
    # Take the actual step of dynamically building serializer
    def _build_serializer_step(current_serializer, k, v, method, record_class, serializer_map)
      if ParamsMagic::Utils.true?(v) || v.respond_to?(:keys)
        klasses = [record_class]
        c = record_class
        ##
        # Handle multi-table inherited models.
        # Specific association may be present not on the model queried
        # but rather its acting_as model. In such a case, we loop through
        # the list of all models and check presence of association on each
        # of them
        while c.respond_to?(:acting_as?) && c.acting_as?
          c = c.acting_as_model.name.constantize
          klasses << c
        end
        klasses.each do |klass|
          reflection = klass.reflect_on_association k
          if reflection
            if serializer_map[k]
              assoc_serializer = serializer_map[k]
            else
              assoc_serializer = "#{reflection.class_name}Serializer".constantize
            end
            if v.respond_to? :keys
              # Recursively build association's serializer
              assoc_serializer = _build_serializer assoc_serializer, reflection.class_name.constantize,
                                                   serializer_map[k] || {}, v[:ones] || {}, v[:manies] || {}
            end
            current_serializer = ParamsMagic::Utils.add_associations method, current_serializer,
                                                                          assoc_name: k,
                                                                          serializer: assoc_serializer
            # No need to continue if current model contains association of interest
            break
          end
        end
      end
      current_serializer
    end

    ##
    # Combines json_pagination and common search
    # together with derivation of serializer plus model name
    # @param fields_like Array, refer to common_search
    # @param fields_eq Array, refer to common_search
    # @param serializer Class, if not passed in, will infer from current controller class
    # @param model Class, if not passed in, will infer from current controller class
    # @param &block block, if not passed in, will call model.all
    def json_search_pagination(fields_like=[], fields_eq=[], fields_comp=[], serializer=nil, model=nil, &block)
      json_pagination serializer do
        if block_given?
          common_search fields_like, fields_eq, fields_comp, &block
        else
          model ||= ParamsMagic::Utils.base_name(self.class).demodulize.constantize
          common_search fields_like, fields_eq, fields_comp do
            model.all
          end
        end
      end
    end

    ##
    # Convenience method for rendering json entries
    def json_pagination(serializer=nil, &block)
      page = params[:page]
      entries = with_pagination &block
      if page
        render_jsons entries, serializer
      else
        render_jsons entries, serializer, false
      end
    end

    def with_pagination
      page = params[:page]
      per = params[:per]
      entries = yield
      if per && per.to_i > ParamsMagic.config.per_page_limit
        per = ParamsMagic.config.per_page_limit
      end
      if per
        entries.page(page).per per
      else
        entries.page page
      end
    end

    ##
    # Deal with common search functions, also deals with sort and ordering
    # 1. If fields_eq is present, try to match on fields_id first
    # 2. If fields_comp is present, try to run filter on columns specified:
    #    For example, fields_comp = [:start_date] would accept parameters of:
    #    - gt_start_date (greater than)
    #    - ge_start_date (greater than or equal to)
    #    - lt_start_date (less than)
    #    - le_start_date (less than or equal to)
    # 3. If keyword is present, run ILIKE on all fields_like passed in (OR relationship)
    # 4. If keyword is not present, run ILIKE on all fields_like if a value is present in
    #    the request (AND relationship)
    #
    # Example, CoursesController could have below:
    # common_search [:name], [:level_id, :subject_id] { #BLOCK# }
    # What happens will be:
    # 1. BLOCK is executed
    # 2. BLOCK results are filtered by :level_id or :subject_id (AND relationship) if passed in as parameter
    # 3. results from step 2 is filtered further by using ILIKE on :name field,
    #    matched against :keyword parameter if it is given in the request
    # 4. If :keyword parameter does not exist and :name parameter is present in the request,
    #    :name parameter value will be matched against :name field using ILIKE
    #
    # For ordering, '_sort' for attribute name, '_direction' for direction, either 'asc' or 'desc'
    def common_search(fields_like=[], fields_eq=[], fields_comp=[])
      entries = yield
      # Deal with fields_id
      fields_eq.each_with_index do |field|
        value = params.delete field
        if value
          value = value.split ',' if value.is_a? String
          entries = entries.where field => value
        end
      end
      # Deal with comparisons
      # Need to parse Date and Time entries
      klass = entries.name.constantize
      fields_comp.each do |field|
        type = klass.columns_hash[field.to_s].type
        if type == :datetime
          parser = Time
        elsif type == :date
          parser = Date
        end
        gt_v, ge_v, lt_v, le_v = *(_extract_prefixed_params params, field, %w(gt_ ge_ lt_ le_)).map do |val|
          begin
            val = parser.parse val if parser
          rescue
            val = nil
          ensure
            val
          end
        end
        entries = _create_comparison entries, field, gt_v, '>'
        entries = _create_comparison entries, field, ge_v, '>='
        entries = _create_comparison entries, field, lt_v, '<'
        entries = _create_comparison entries, field, le_v, '<='
      end
      # Deal with keyword
      keyword = params[:keyword]
      if keyword
        query = ''
        fields_like.each_with_index do |field, idx|
          query += "#{field} ILIKE ?"
          unless idx == fields_like.size - 1
            query += ' OR '
          end
        end
        entries = entries.where query, *(["%#{keyword}%"]*fields_like.size)
      else
        # Deal with individual fields
        fields_like.each do |field|
          value = params.delete field
          entries = entries.where "#{field} ILIKE ?", "%#{value}%" if value
        end
      end
      # Deal with _sort and _direction
      if params[:_sort].present?
        col = params[:_sort]
        direction = params[:_direction] == 'desc' ? :desc : :asc
        klasses = [klass]
        c = klass
        ##
        # Handle multi-table inherited models.
        # Specific association may be present not on the model queried
        # but rather its acting_as model. In such a case, we loop through
        # the list of all models and check presence of association on each
        # of them
        while c.respond_to?(:acting_as?) && c.acting_as?
          c = c.acting_as_model.name.constantize
          klasses << c
        end
        found = false
        klasses.each do |c|
          if c.column_names.include? col
            # No need to continue if current model contains method of interest
            found = true
            break
          end
        end
        if found
          entries = entries.reorder col.to_sym => direction
        end
      end
      entries
    end

    ##
    # Combine common_search and pagination
    def search_pagination(fields_like=[], fields_eq=[], fields_comp=[], &block)
      if block_given?
        common_search(fields_like, fields_eq, fields_comp) { with_pagination &block }
      else
        model ||= ParamsMagic::Utils.base_name(self.class).demodulize.constantize
        common_search fields_like, fields_eq, fields_comp do
          with_pagination { model.all }
        end
      end
    end

    def _create_comparison(entries, field, value, symbol)
      value ? entries.where("#{field} #{symbol} ?", value) : entries
    end

    def _extract_prefixed_params(params, field, prefixes)
      results = prefixes.map do |pf|
        params["#{pf}#{field}".to_sym]
      end
      return results
    end

    ##
    # If params[:id] is present, try to find model based on it
    # and set it as an instance variable
    # This involves deducing model Class and instance variable name
    #
    # This works in below situations:
    # 1. MODULE::WhateverController -> @whatever = Whatever.find param[:id]
    # 2. WhateverController -> @whatever = Whatever.find param[:id]
    #
    # +add_associations+, additional object ids, for example:
    #   individual_id: 3 will trigger below action:
    #   @individual = Individual.find 3
    def set_resource(options={}, *additional_ids)
      options = { friendly_id: false }.merge options
      kv_map = {}
      additional_ids.each do |id_key|
        id_key = id_key.to_s
        # Has to end with _id
        if id_key.end_with? '_id'
          id = params[id_key]
          if id
            base = id_key[0..-4].classify
            kv_map[base] = id
          end
        end
      end
      id = params[:id]
      if id
        base = ParamsMagic::Utils.base_name(self.class).demodulize
        kv_map[base] = id
      end
      kv_map.each do |k,v|
        klass = k.constantize
        instance_variable_set "@#{k.underscore}", (options[:friendly_id] ? klass.friendly.find(v) : klass.find(v))
      end
    end

    def set_associations(options={})
      @_serializers = options.delete :serializers || {}
      ones = {}
      manies = {}
      @_associations = { ones: ones, manies: manies }
      many = 'with_many_'
      one = 'with_one_'
      # Clean-up
      params.each do |k, v|
        if k.start_with?(many) && (ParamsMagic::Utils.true?(v) || v.respond_to?(:keys))
          key = k.to_s.sub many, ''
          entry = v.respond_to?(:keys) ? v : true
          manies[key] = entry
        elsif k.start_with?(one) && (ParamsMagic::Utils.true?(v) || v.respond_to?(:keys))
          key = k.to_s.sub one, ''
          entry = v.respond_to?(:keys) ? v : true
          ones[key] =entry
        elsif k == 'with_manies'
          manies.merge! v
        elsif k == 'with_ones'
          ones.merge! v
        end
      end
    end
  end
end