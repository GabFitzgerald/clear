# ```
# class Model
#   include Clear::Model
#
#   has_many posts : Post, [ foreign_key: Model.underscore_name + "_id", no_cache : false]
#
#   has_one passport : Passport
#   has_many posts
# ```
module Clear::Model::HasRelations
  # The method `has_one` declare a relation 1 to [0,1]
  # where the current model primary key is stored in the foreign table.
  # `primary_key` method (default: `self#pkey`) and `foreign_key` method
  # (default: table_name in singular, plus "_id" appended)
  # can be redefined
  #
  # Examples:
  # ```
  # model Passport
  #   column id : Int32, primary : true
  #   has_one user : User It assumes the table `users` have a column `passport_id`
  # end
  #
  # model Passport
  #   column id : Int32, primary : true
  #   has_one owner : User # It assumes the table `users` have a column `passport_id`
  # end
  # ```
  macro has_one(name, foreign_key = nil, primary_key = nil)
    {% relation_type = name.type %}
    {% method_name = name.var.id %}

    # `{{method_name}}` is of type `has_one` relation to {{relation_type}}
    def {{method_name}} : {{relation_type}}?
      %primary_key = {{(primary_key || "pkey").id}}
      %foreign_key =  {{foreign_key}} || ( self.class.table.to_s.singularize + "_id" )

      {{relation_type}}.query.where{ raw(%foreign_key) == %primary_key }.first
    end

    def {{method_name}}! : {{relation_type}}
      {{method_name}}.not_nil!
    end

    # Addition of the method for eager loading and N+1 avoidance.
    class Collection
      # Eager load the relation {{method_name}}.
      # Use it to avoid N+1 queries.
      def with_{{method_name}}(fetch_columns = false) : self
        before_query do
          %primary_key = {{(primary_key || "#{relation_type}.pkey").id}}
          %foreign_key =  {{foreign_key}} || ( {{@type}}.table.to_s.singularize + "_id" )

          %table = {{@type}}.esc_schema_table
          #SELECT * FROM foreign WHERE foreign_key IN ( SELECT primary_key FROM users )
          sub_query = self.dup.clear_select.select(
            { %table, Clear::SQL.escape(%primary_key) }.join(".")
          )

          @cache.active "{{method_name}}"

          {{relation_type}}.query.where{ raw(%foreign_key).in?(sub_query) }.each(fetch_columns: true) do |mdl|
            @cache.set(
              "#{%table}.{{method_name}}", mdl.attributes[%foreign_key], [mdl]
            )
          end
        end

        self
      end
    end
  end

  # has_many through
  macro has_many(name, through, own_key = nil, foreign_key = nil)
    {% relation_type = name.type %}
    {% method_name = name.var.id %}

    def {{method_name}} : {{relation_type}}::Collection
      %final_table = {{relation_type}}.table
      %final_pkey = {{relation_type}}.pkey
      %through_table = {% if through.is_a?(SymbolLiteral) || through.is_a?(StringLiteral) %}
        {{through.id.stringify}}
      {% else %}
        {{through}}.table
      {% end %}

      %through_key = {{foreign_key}} || {{relation_type}}.table.to_s.singularize + "_id"
      %own_key = {{own_key}} || {{@type}}.table.to_s.singularize + "_id"

      cache = @cache

      qry = {{relation_type}}.query.select("#{Clear::SQL.escape(%final_table)}.*")
        .join(Clear::SQL.escape(%through_table)){
          var(%through_table, %through_key) == var(%final_table, %final_pkey)
        }.where{
          # FIXME: self.id or self.pkey ?
          var(%through_table, %own_key) == self.id
        }.distinct("#{Clear::SQL.escape(%final_table)}.#{Clear::SQL.escape(%final_pkey)}")


      if cache && cache.active?("{{method_name}}")
        arr = cache.hit("{{method_name}}", self.pkey, {{relation_type}})
        qry.with_cached_result(arr)
      end

      qry
    end

    # Addition of the method for eager loading and N+1 avoidance.
    class Collection
      # Eager load the relation {{method_name}}.
      # Use it to avoid N+1 queries.
      def with_{{method_name}}(&block : {{relation_type}}::Collection -> ) : self
        before_query do
          %final_table = {{relation_type}}.table
          %final_pkey = {{relation_type}}.pkey
          %through_table = {{through}}.table
          %through_key = {{foreign_key}} || {{relation_type}}.table.to_s.singularize + "_id"
          %own_key = {{own_key}} || {{@type}}.table.to_s.singularize + "_id"
          self_type = {{@type}}

          @cache.active "{{method_name}}"

          sub_query = self.dup.clear_select.select("#{{{@type}}.table}.#{self_type.pkey}")

          qry = {{relation_type}}.query.join(%through_table){
            var(%through_table, %through_key) == var(%final_table, %final_pkey)
          }.where{
            var(%through_table, %own_key).in?(sub_query)
          }.distinct.select( "#{Clear::SQL.escape(%final_table)}.*",
            "#{Clear::SQL.escape(%through_table)}.#{Clear::SQL.escape(%own_key)} AS __own_id"
          )

          block.call(qry)

          h = {} of Clear::SQL::Any => Array({{relation_type}})

          qry.each(fetch_columns: true) do |mdl|
            unless h[mdl.attributes["__own_id"]]?
              h[mdl.attributes["__own_id"]] = [] of {{relation_type}}
            end

            h[mdl.attributes["__own_id"]] << mdl
          end

          h.each do |key, value|
            @cache.set("{{method_name}}", key, value)
          end
        end

        self
      end

      def with_{{method_name}}
        with_{{method_name}}{}
      end

    end

  end

  # has many
  macro has_many(name, foreign_key = nil, primary_key = nil)
    {% relation_type = name.type %}
    {% method_name = name.var.id %}

    # The method {{method_name}} is a `has_many` relation
    #   to {{relation_type}}
    def {{method_name}} : {{relation_type}}::Collection
      %primary_key = {{(primary_key || "pkey").id}}
      %foreign_key =  {{foreign_key}} || ( self.class.table.to_s.singularize + "_id" )


      cache = @cache
      if cache && cache.active?("{{method_name}}")
        arr = cache.hit("{{method_name}}", %primary_key, {{relation_type}})

        # This relation will trigger the cache if it exists
        {{relation_type}}.query \
          .tags({ "#{%foreign_key}" => "#{%primary_key}" }) \
          .where{ raw(%foreign_key) == %primary_key }
          .with_cached_result(arr)
      else
        {{relation_type}}.query \
          .tags({ "#{%foreign_key}" => "#{%primary_key}" }) \
          .where{ raw(%foreign_key) == %primary_key }
      end
      #end
    end

    # Addition of the method for eager loading and N+1 avoidance.
    class Collection
      # Eager load the relation {{method_name}}.
      # Use it to avoid N+1 queries.
      def with_{{method_name}}(fetch_columns = false, &block : {{relation_type}}::Collection -> ) : self
        before_query do
          %primary_key = {{(primary_key || "#{relation_type}.pkey").id}}
          %foreign_key =  {{foreign_key}} || ( {{@type}}.table.to_s.singularize + "_id" )

          #SELECT * FROM foreign WHERE foreign_key IN ( SELECT primary_key FROM users )
          sub_query = self.dup.clear_select.select("#{{{@type}}.table}.#{%primary_key}")

          qry = {{relation_type}}.query.where{ raw(%foreign_key).in?(sub_query) }
          block.call(qry)

          @cache.active "{{method_name}}"

          h = {} of Clear::SQL::Any => Array({{relation_type}})

          qry.each(fetch_columns: true) do |mdl|
            unless h[mdl.attributes[%foreign_key]]?
              h[mdl.attributes[%foreign_key]] = [] of {{relation_type}}
            end

            h[mdl.attributes[%foreign_key]] << mdl
          end

          h.each do |key, value|
            @cache.set("{{method_name}}", key, value)
          end
        end

        self
      end

      def with_{{method_name}}(fetch_columns = false)
        with_{{method_name}}(fetch_columns){|q|} #empty block
      end
    end
  end

  # ```
  # class Model
  #   include Clear::Model
  #   belongs_to user : User, foreign_key: "the_user_id"
  #
  # ```
  macro belongs_to(name, foreign_key = nil, no_cache = false, primary = false, key_type = Int64?)
    {% relation_type = name.type %}
    {% method_name = name.var.id %}
    {% foreign_key = foreign_key || method_name.stringify.underscore + "_id" %}

    column {{foreign_key.id}} : {{key_type}}, primary: {{primary}}
    getter _cached_{{method_name}} : {{relation_type}}?

    # The method {{method_name}} is a `belongs_to` relation
    #   to {{relation_type}}
    def {{method_name}} : {{relation_type}}?
      if @cached_{{method_name}}
        @cached_{{method_name}}
      else
        cache = @cache

        if cache && cache.active? "{{method_name}}"
          @cached_{{method_name}} = cache.hit("{{method_name}}", self.{{foreign_key.id}}, {{relation_type}}).first?
        else
          @cached_{{method_name}} = {{relation_type}}.query.where{ raw({{relation_type}}.pkey) == self.{{foreign_key.id}} }.first
        end

      end
    end

    def {{method_name}}! : {{relation_type}}
      {{method_name}}.not_nil!
    end

    def {{method_name}}=(x : {{relation_type}}?)
      if x.persisted?
        raise "#{x.pkey_column.name} must be defined when assigning a belongs_to relation." unless x.pkey_column.defined?
        @cached_{{method_name}} = x
        @{{foreign_key.id}}_column.value = x.pkey
      else
        @cached_{{method_name}} = x
      end
    end

    # :nodoc:
    # save the belongs_to model first if needed
    def _bt_save_{{method_name}}
      c = @cached_{{method_name}}
      return if c.nil?

      unless c.persisted?
        if c.save
          @{{foreign_key.id}}_column.value = c.pkey
        else
          add_error("{{method_name}}", c.print_errors)
        end
      end
    end

    before(:validate, _bt_save_{{method_name}})

    class Collection
      def with_{{method_name}}(fetch_columns = false, &block : {{relation_type}}::Collection -> ) : self
        before_query do
          sub_query = self.dup.clear_select.select("#{{{@type}}.table}.{{foreign_key.id}}")

          cached_qry = {{relation_type}}.query.where{ raw({{relation_type}}.pkey).in?(sub_query) }

          block.call(cached_qry)

          @cache.active "{{method_name}}"

          cached_qry.each(fetch_columns: fetch_columns) do |mdl|
            @cache.set("{{method_name}}", mdl.pkey, [mdl])
          end
        end

        self
      end

      def with_{{method_name}}(fetch_columns = false) : self
        with_{{method_name}}(fetch_columns){}
        self
      end

    end

  end
end
