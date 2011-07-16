# suppress warnings
old_verbose, $VERBOSE = $VERBOSE, nil
# require thrift autogenerated files
require File.join(File.dirname(__FILE__), *%w[.. thrift thrift_hive])
# restore warnings
$VERBOSE = old_verbose

module RBHive
  def connect(server, port=10_000)
    connection = RBHive::Connection.new(server, port)
    ret = nil
    begin
      connection.open
      ret = yield(connection)
    ensure
      connection.close
      ret
    end
  end
  module_function :connect
  
  class StdOutLogger
    %w(fatal error warn info debug).each do |level| 
      define_method level.to_sym do |message|
        STDOUT.puts(message)
     end
   end
  end
  
  class Connection
    attr_reader :client
    
    def initialize(server, port=10_000, logger=StdOutLogger.new)
      @socket = Thrift::Socket.new(server, port)
      @transport = Thrift::BufferedTransport.new(@socket)
      @protocol = Thrift::BinaryProtocol.new(@transport)
      @client = ThriftHive::Client.new(@protocol)
      @logger = logger
      @logger.info("Connecting to #{server} on port #{port}")
    end
    
    def open
      @transport.open
    end
    
    def close
      @transport.close
    end
    
    def client
      @client
    end
    
    def execute(query)
      @logger.info("Executing Hive Query: #{query}")
      client.execute(query)
    end
    
    def priority=(priority)
      set("mapred.job.priority", priority)
    end
    
    def queue=(queue)
      set("mapred.job.queue.name", queue)
    end
    
    def set(name,value)
      @logger.info("Setting #{name}=#{value}")
      client.execute("SET #{name}=#{value}")
    end
    
    def fetch(query)
      execute(query)
      ResultSet.new(client.fetchAll, client.getSchema)
    end
    
    def fetch_in_batch(query, batch_size=100)
      execute(query)
      until (next_batch = client.fetchN(batch_size)).empty?
        yield ResultSet.new(next_batch)
      end
    end
    
    def first(query)
      execute(query)
      ResultSet.new([client.fetchOne])
    end
    
    def create_table(schema)
      execute(schema.create_table_statement)
    end
    
    def drop_table(name)
      name = name.name if name.is_a?(TableSchema)
      execute("DROP TABLE `#{name}`")
    end
    
    def replace_columns(schema)
      execute(schema.replace_columns_statement)
    end
    
    def add_columns(schema)
      execute(schema.add_columns_statement)
    end
    
    def method_missing(meth, *args)
      client.send(meth, *args)
    end
  end
  
  class SchemaDefinition
    attr_reader :schema
    
    TYPES = { 
      :boolean => :to_s, 
      :string => :to_s, 
      :bigint => :to_i, 
      :float => :to_f, 
      :double => :to_f, 
      :int => :to_i, 
      :smallint => :to_i, 
      :tinyint => :to_i
    }
    
    def initialize(schema, example_row)
      @schema = schema
      @example_row = example_row.split("\t")
    end
    
    def column_names
      @column_names ||= begin
        schema_names = @schema.fieldSchemas.map {|c| c.name.to_sym }
        # Lets fix the fact that Hive doesn't return schema data for partitions on SELECT * queries
        # For now we will call them :_p1, :_p2, etc. to avoid collisions.
        offset = 0
        while schema_names.length < @example_row.length
          schema_names.push(:"_p#{offset+=1}")
        end
        schema_names
      end
    end
    
    def column_type_map
      @column_type_map ||= column_names.inject({}) do |hsh, c| 
        definition = @schema.fieldSchemas.find {|s| s.name.to_sym == c }
        # If the column isn't in the schema (eg partitions in SELECT * queries) assume they are strings
        hsh[c] = definition ? definition.type.to_sym : :string
        hsh
      end
    end
    
    def coerce_row(row)
      column_names.zip(row.split("\t")).inject({}) do |hsh, (column_name, value)|
        hsh[column_name] = coerce_column(column_name, value)
        hsh
      end
    end
    
    def coerce_column(column_name, value)
      type = column_type_map[column_name]
      conversion_method = TYPES[type]
      conversion_method ? value.send(conversion_method) : value
    end
    
    def coerce_row_to_array(row)
      column_names.map { |n| row[n] }
    end
  end
  
  class ResultSet < Array
    def initialize(rows, schema=[])
      @schema = SchemaDefinition.new(schema, rows.first)
      super(rows.map {|r| @schema.coerce_row(r) })
    end
    
    def column_names
      @schema.column_names
    end
    
    def column_type_map
      @schema.column_type_map
    end
    
    def to_csv(out_file=nil)
      output(",", out_file)
    end
    
    def to_tsv(out_file=nil)
      output("\t", out_file)
    end
    
    private
    
    def output(sep, out_file)
      rows = self.map { |r| @schema.coerce_row_to_array(r).join(sep) }
      sv = rows.join("\n")
      return sv if out_file.nil?
      File.open(out_file, 'w+') { |f| f << sv }
    end
  end
end
