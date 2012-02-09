require 'sinatra/sparql'
require 'sinatra/partials'
require 'sinatra/respond_to'
require 'erubis'
require 'linkeddata'
require 'rdf/portal/extensions'
require 'uri'

module RDF::Portal
  class Application < Sinatra::Base
    register Sinatra::RespondTo
    register Sinatra::SPARQL
    helpers Sinatra::Partials
    set :views, ::File.expand_path('../views',  __FILE__)
    DOAP_FILE = File.expand_path("../../../../etc/doap.nt", __FILE__)

    mime_type "sse", "application/sse+sparql-query"
    before do
      puts "[#{request.path_info}], #{params.inspect}, #{format}, #{request.accept.inspect}"
    end

    get '/' do
      cache_control :public, :must_revalidate, :max_age => 60
      erb :index, :locals => {:title => "Ruby Linked Data Service"}
    end

    get '/about' do
      cache_control :public, :must_revalidate, :max_age => 60
      erb :about, :locals => {:title => "About the Ruby Linked Data Service"}
    end

    get '/doap' do
      cache_control :public, :must_revalidate, :max_age => 60
      if format == :nt
        headers "Content-Type" => "text/plain"
        body File.read(DOAP_FILE)
      else
        doap
      end
    end

    get '/distiller' do
      cache_control :public, :must_revalidate, :max_age => 60
      distil
    end

    post '/distiller' do
      distil
    end
    
    get '/sparql' do
      cache_control :public, :must_revalidate, :max_age => 60
      sparql
    end

    post '/sparql' do
      sparql
    end

    private

    # Handle GET/POST /distiller
    def distil
      writer_options = {
        :standard_prefixes => true,
        :prefixes => {},
        :base_uri => params["uri"],
      }
      writer_options[:format] = params["fmt"] || "turtle"

      content = parse(writer_options)
      puts "distil content: #{content.class}, as type #{format.inspect}, content-type: #{content.inspect}"

      if params["fmt"].to_s == "rdfa"
        # If the format is RDFa, use specific HAML writer
        haml = DISTILLER_HAML.dup
        root = request.url[0,request.url.index(request.path)]
        haml[:doc] = haml[:doc].gsub(/--root--/, root)
        writer_options[:haml] = haml
        writer_options[:haml_options] = {:ugly => false}
      end
      settings.sparql_options.replace(writer_options)

      if format != :html || params["raw"]
        # Return distilled content as is
        content
      else
        @output = case content
        when RDF::Enumerable
          # For HTML response, the "fmt" attribute may set the type of serialization
          fmt = (params["fmt"] || "ttl").to_sym
          content.dump(fmt, writer_options)
        else
          content
        end
        erb :distiller, :locals => {:title => "RDF Distiller", :head => :distiller}
      end
    end
    
    # Handle GET/POST /sparql
    def sparql
      writer_options = {
        :standard_prefixes => true,
        :prefixes => {},
      }
      # Override output format if returning something that is raw, or if
      # the "fmt" argument is used and the output format isn't HTML
      format :xml if format == :xsl # Problem with content detection
      format params["fmt"] if params["raw"] && params.has_key?("fmt")
      format params["fmt"] if params.has_key?("fmt") && format != :html
      params["fmt"] ||= format

      content = query

      if params["fmt"].to_s == "rdfa"
        # If the format is RDFa, use specific HAML writer
        haml = DISTILLER_HAML.dup
        root = request.url[0,request.url.index(request.path)]
        haml[:doc] = haml[:doc].gsub(/--root--/, root)
        writer_options[:haml] = haml
        writer_options[:haml_options] = {:ugly => false}
      end

      puts "sparql content: #{content.class}, as type #{format.inspect} with options #{writer_options.inspect}"
      if format != :html
        writer_options[:format] = format
        settings.sparql_options.replace(writer_options)
        content
      else
        serialize_options = {
          :format => params["fmt"],
          :content_types => request.accept
        }
        begin
          @output = SPARQL.serialize_results(content, serialize_options)
        rescue RDF::WriterError => e
          @error = "No results generated #{content.class}: #{e.message}"
        end
        erb :sparql, :locals => {
          :title => "SPARQL Endpoint",
          :head => :distiller,
          :doap_count => doap.count
        }
      end
    end

    # Format symbol for RDF formats
    # @param [Symbol] reader_or_writer
    # @return [Array<Symbol>] List of format symbols
    def formats(reader_or_writer = nil)
      # Symbols for different input formats
      RDF::Reader.each.to_a.map(&:to_sym)  
    end

    ## Default graph, loaded from DOAP file
    def doap
      @doap ||= begin
        puts "load #{DOAP_FILE}"
        RDF::Repository.load(DOAP_FILE)
      end
    end

    # Parse the an input file and re-serialize based on params and/or content-type/accept headers
    def parse(options)
      reader_opts = options.merge(
        :validate => params["validate"],
        :expand => params["expand"]
      )
      reader_opts[:format] = params["in_fmt"].to_sym unless (params["in_fmt"] || 'content') == 'content'
      reader_opts[:debug] = @debug = [] if params["debug"]
      
      graph = RDF::Repository.new
      in_fmt = params["in_fmt"].to_sym if params["in_fmt"]

      # Load data into graph
      case
      #when !params["datafile"].to_s.empty?
      #  raise RDF::ReaderError, "Specify input format" if in_fmt.nil? || in_fmt == :content
      #  puts "Open datafile with format #{in_fmt}"
      #  tempfile = params["datafile"][:tempfile]
      #  reader = RDF::Reader.for(reader_opts[:format] || reader_opts) { tempfile.read }
      #  tempfile.rewind
      #  puts "found reader #{reader.class} for tempfile" unless reader_opts[:format]
      #  reader.new(tempfile, reader_opts) {|r| graph << r}
      when !params["content"].to_s.empty?
        raise RDF::ReaderError, "Specify input format" if in_fmt.nil? || in_fmt == :content
        @content = ::URI.unescape(params["content"])
        puts "Open form data with format #{in_fmt} for #{@content.inspect}"
        reader = RDF::Reader.for(reader_opts[:format] || reader_opts)
        reader.new(@content, reader_opts) {|r| graph << r}
      when !params["uri"].to_s.empty?
        puts "Open uri <#{params["uri"]}> with format #{in_fmt}"
        reader = RDF::Reader.open(params["uri"], reader_opts) {|r| graph << r}
        params["in_fmt"] = reader.class.to_sym if in_fmt.nil? || in_fmt == :content
      else
        graph = ""
      end

      puts "parsed #{graph.count} statements" if graph.is_a?(RDF::Graph)
      graph
    rescue RDF::ReaderError => e
      @error = "RDF::ReaderError: #{e.message}"
      puts @error  # to log
      nil
    rescue
      raise unless settings.environment == :production
      @error = "#{$!.class}: #{$!.message}"
      puts @error  # to log
      nil
    end

    # Perform a SPARQL query, either on the input URI or the form data
    def query
      sparql_opts = {
        :base_uri => params["uri"],
        :validate => params["validate"],
      }
      sparql_opts[:format] = params["fmt"].to_sym if params["fmt"]
      sparql_opts[:debug] = @debug = [] if params["debug"]

      sparql_expr = nil

      case
      when !params["query"].to_s.empty?
        @query = params["query"]
        puts "Open form data: #{@query.inspect}"
        sparql_expr = SPARQL.parse(@query, sparql_opts)
      when !params["uri"].to_s.empty?
        puts "Open uri <#{params["uri"]}>"
        RDF::Util::File.open_file(params["uri"]) do |f|
          sparql_expr = SPARQL.parse(f, sparql_opts)
        end
      else
        # Otherwise, return service description
        puts "Service Description"
        return case format
        when :html
          ""  # Done in form
        else
          # Return service description graph
          service_description(:repository => doap, :endpoint => url("/sparql"))
        end
      end

      raise "No SPARQL query created" unless sparql_expr

      if params["fmt"].to_s == "sse"
        headers = ["Content-Type" => "application/sse+sparql-query"]
        return sparql_expr.to_sxp
      end

      puts "execute query"
      sparql_expr.execute(doap, sparql_opts)
    rescue SPARQL::Grammar::Parser::Error, SPARQL::MalformedQuery, TypeError
      @error = "#{$!.class}: #{$!.message}"
      puts @error  # to log
      nil
    rescue
      raise unless settings.environment == :production
      @error = "#{$!.class}: #{$!.message}"
      puts @error  # to log
      nil
    end
  end
end