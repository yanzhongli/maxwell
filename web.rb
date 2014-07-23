require 'bundler/setup'
$LOAD_PATH << File.expand_path(File.dirname(__FILE__))

require 'sinatra'
require 'json'
require 'lib/setup_java'
require 'lib/schema'
require 'lib/binlog_dir'
require 'lib/config'

set :run, false

class Web < Sinatra::Base
  set :config, BinlogConfig.new
  set :server, 'puma'
  set :port, settings.config.api_port
  set :run, false

  def require_params(*required)
    missing = required.select { |p| !params[p] }
    if missing.any?
      status 422
      body({err: "Please provide the following parameter(s): #{missing.join(',')}"}.to_json)
      false
    else
      true
    end
  end

  before do
    content_type :json
  end

  # capture the schema at a position.
  #
  # return both the schema and the current position of the binlog for future requests
  # required parameter: db
  get "/mark_binlog_top" do
    return unless require_params(:db)

    schema = Schema.new(settings.config.mysql_connection, params[:db])
    s = schema.fetch
    schema.save
    status 200
    body schema.binlog_info.merge(schema: s).to_json
  end

  # begin playing the binlog from a specified position.
  # The position *must* be one returned from mark_binlog_top
  #
  # required parameters: account_id, db, start_file, start_pos
  # optional paramerers: end_file, end_pos
  #
  get "/binlog_events" do
    return unless require_params(:account_id, :db, :start_file, :start_pos)
    schema = Schema.load(params[:db], params[:start_file], params[:start_pos].to_i)

    if schema.nil?
      status 404
      body({err: "No stored schema found for #{params[:start_file]}:#{params[:start_pos]} -- call mark_binlog_top",
            type: "no_stored_schema"}.to_json)
      return
    end

    begin
      sql = []
      start_info = { file: params[:start_file], pos: params[:start_pos].to_i }

      if params[:end_file] && params[:end_pos]
        end_info = {file: params[:end_file], pos: params[:end_pos].to_i}
      end

      d = BinlogDir.new(settings.config.binlog_dir, schema)

      filter = { 'account_id' => params[:account_id].to_i }
      info = d.read_binlog(filter, start_info, end_info, params[:max_events] ? params[:max_events].to_i : nil) do |event|
        s = event.to_sql(filter)
        sql << s if s
      end

      next_pos = {file: info[:file], pos: info[:pos]}
      processed = info[:processed]

      status 200
      body({next_pos: next_pos, processed: info[:processed], sql: sql}.to_json)

    rescue SchemaChangedError => e
      status 500
      body({err: e.message, type: 'schema_changed'}.to_json)
    end
  end
end

if __FILE__ == $0
  Web.run!
end