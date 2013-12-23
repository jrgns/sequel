require 'tiny_tds'
Sequel.require 'adapters/shared/mssql'

module Sequel
  module TinyTDS
    class Database < Sequel::Database
      include Sequel::MSSQL::DatabaseMethods
      set_adapter_scheme :tinytds

      # Transfer the :user option to the :username option.
      def connect(server)
        opts = server_opts(server)
        opts[:username] = opts[:user]
        c = TinyTds::Client.new(opts)
        c.query_options.merge!(:cache_rows=>false)

        if (ts = opts[:textsize])
          sql = "SET TEXTSIZE #{typecast_value_integer(ts)}"
          log_yield(sql){c.execute(sql)}
        end
      
        c
      end
      
      # Execute the given +sql+ on the server.  If the :return option
      # is present, its value should be a method symbol that is called
      # on the TinyTds::Result object returned from executing the
      # +sql+.  The value of such a method is returned to the caller.
      # Otherwise, if a block is given, it is yielded the result object.
      # If no block is given and a :return is not present, +nil+ is returned.
      def execute(sql, opts=OPTS)
        synchronize(opts[:server]) do |c|
          begin
            m = opts[:return]
            r = nil
            if (args = opts[:arguments]) && !args.empty?
              types = []
              values = []
              declarations = []
              outputs = []
              args.each_with_index do |(k, v), i|
                out = k.end_with? 'OUT'
                v, type = ps_arg_type(v)
                if out
                  k = k.chomp('OUT')
                  declarations << "@#{k} #{type}"
                  outputs << "@#{k} AS #{k}"
                  types << "@#{k}OUT #{type} OUTPUT"
                  values << "@#{k}OUT = @#{k} OUTPUT"
                else
                  types << "@#{k} #{type}"
                  values << "@#{k} = #{v}"
                end
              end
              out = outputs.length > 0
              case m
              when :do
                sql = "#{sql}; SELECT @@ROWCOUNT AS AffectedRows"
                single_value = true
              when :insert
                sql = "#{sql}; SELECT CAST(SCOPE_IDENTITY() AS bigint) AS Ident"
                single_value = true
              end
              sql = "EXEC sp_executesql N'#{c.escape(sql)}', N'#{c.escape(types.join(', '))}', #{values.join(', ')}"
              if out
                sql = "DECLARE #{declarations.join(', ')}; #{sql}; SELECT #{outputs.join(', ')}, @@ROWCOUNT AS AffectedRows"
              end
              log_yield(sql) do
                r = c.execute(sql)
                r.each{|row| return row.values.first} if single_value
                return r.first if out
              end
            else
              log_yield(sql) do
                r = c.execute(sql)
                return r.send(m) if m
              end
            end
            yield(r) if block_given?
          rescue TinyTds::Error => e
            raise_error(e, :disconnect=>!c.active?)
          ensure
           r.cancel if r && c.sqlsent?
          end
        end
      end

      # Return the number of rows modified by the given +sql+.
      def execute_dui(sql, opts=OPTS)
        execute(sql, opts.merge(:return=>:do))
      end

      # Return the value of the autogenerated primary key (if any)
      # for the row inserted by the given +sql+.
      def execute_insert(sql, opts=OPTS)
        execute(sql, opts.merge(:return=>:insert))
      end

      # Execute the DDL +sql+ on the database and return nil.
      def execute_ddl(sql, opts=OPTS)
        execute(sql, opts.merge(:return=>:each))
        nil
      end

      private

      # Choose whether to use unicode strings on initialization
      def adapter_initialize
        set_mssql_unicode_strings
      end
      
      # For some reason, unless you specify a column can be
      # NULL, it assumes NOT NULL, so turn NULL on by default unless
      # the column is a primary key column.
      def column_list_sql(g)
        pks = []
        g.constraints.each{|c| pks = c[:columns] if c[:type] == :primary_key} 
        g.columns.each{|c| c[:null] = true if !pks.include?(c[:name]) && !c[:primary_key] && !c.has_key?(:null) && !c.has_key?(:allow_null)}
        super
      end

      # tiny_tds uses TinyTds::Error as the base error class.
      def database_error_classes
        [TinyTds::Error]
      end

      # Stupid MSSQL maps foreign key and check constraint violations
      # to the same error code, and doesn't expose the sqlstate.  Use
      # database error numbers if present and unambiguous, otherwise
      # fallback to the regexp mapping.
      def database_specific_error_class(exception, opts)
        case exception.db_error_number
        when 515
          NotNullConstraintViolation
        when 2627
          UniqueConstraintViolation
        else
          super
        end
      end

      # Return true if the :conn argument is present and not active.
      def disconnect_error?(e, opts)
        super || (opts[:conn] && !opts[:conn].active?)
      end

      # Dispose of any possible results of execution.
      def log_connection_execute(conn, sql)
        log_yield(sql){conn.execute(sql).each}
      end

      # Return a 2 element array with the literal value and type to use
      # in the prepared statement call for the given value and connection.
      def ps_arg_type(v)
        case v
        when Fixnum
          [v, 'int']
        when Bignum
          [v, 'bigint']
        when Float
          [v, 'double precision']
        when Numeric
          [v, 'numeric']
        when Time
          if v.is_a?(SQLTime)
            [literal(v), 'time']
          else
            [literal(v), 'datetime']
          end
        when DateTime
          [literal(v), 'datetime']
        when Date
          [literal(v), 'date']
        when nil
          ['NULL', 'nvarchar(max)']
        when true
          ['1', 'int']
        when false
          ['0', 'int']
        when SQL::Blob
          [literal(v), 'varbinary(max)']
        else
          [literal(v), 'nvarchar(max)']
        end
      end
    end
    
    class Dataset < Sequel::Dataset
      include Sequel::MSSQL::DatasetMethods

      Database::DatasetClass = self
      
      # SQLite already supports named bind arguments, so use directly.
      module ArgumentMapper
        include Sequel::Dataset::ArgumentMapper
        
        protected
        
        # Return a hash with the same values as the given hash,
        # but with the keys converted to strings.
        def map_to_prepared_args(hash)
          args = {}
          hash.each{|k,v| args[k.to_s.gsub('.', '__')] = v}
          args
        end
        
        private
        
        # SQLite uses a : before the name of the argument for named
        # arguments.
        def prepared_arg(k)
          LiteralString.new("@#{k.to_s.gsub('.', '__')}")
        end

        # Always assume a prepared argument.
        def prepared_arg?(k)
          true
        end
      end
      
      # SQLite prepared statement uses a new prepared statement each time
      # it is called, but it does use the bind arguments.
      module PreparedStatementMethods
        include ArgumentMapper
        
        private
        
        # Run execute_select on the database with the given SQL and the stored
        # bind arguments.
        def execute(sql, opts=OPTS, &block)
          super(prepared_sql, {:arguments=>bind_arguments}.merge(opts), &block)
        end
        
        # Same as execute, explicit due to intricacies of alias and super.
        def execute_dui(sql, opts=OPTS, &block)
          super(prepared_sql, {:arguments=>bind_arguments}.merge(opts), &block)
        end
        
        # Same as execute, explicit due to intricacies of alias and super.
        def execute_insert(sql, opts=OPTS, &block)
          super(prepared_sql, {:arguments=>bind_arguments}.merge(opts), &block)
        end
      end
      
      # Yield hashes with symbol keys, attempting to optimize for
      # various cases.
      def fetch_rows(sql)
        execute(sql) do |result|
          @columns = result.fields.map!{|c| output_identifier(c)}
          if db.timezone == :utc
            result.each(:timezone=>:utc){|r| yield r}
          else
            result.each{|r| yield r}
          end
        end
        self
      end
      
      # Create a named prepared statement that is stored in the
      # database (and connection) for reuse.
      def prepare(type, name=nil, *values)
        ps = to_prepared_statement(type, values)
        ps.extend(PreparedStatementMethods)
        if name
          ps.prepared_statement_name = name
          db.set_prepared_statement(name, ps)
        end
        ps
      end
      
      private
      
      # Properly escape the given string +v+.
      def literal_string_append(sql, v)
        sql << (mssql_unicode_strings ? UNICODE_STRING_START : APOS)
        sql << db.synchronize(@opts[:server]){|c| c.escape(v)}.gsub(BACKSLASH_CRLF_RE, BACKSLASH_CRLF_REPLACE) << APOS
      end
    end
  end
end
