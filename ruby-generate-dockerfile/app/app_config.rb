# Copyright 2017 Google Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require "json"
require "net/http"
require "optparse"
require "psych"

class AppConfig
  DEFAULT_WORKSPACE_DIR = "/workspace"
  DEFAULT_APP_YAML_PATH = "./app.yaml"
  DEFAULT_RACK_ENTRYPOINT = "bundle exec rackup -p $PORT"
  DEFAULT_SERVICE_NAME = "default"

  class Error < ::StandardError
  end

  attr_reader :workspace_dir
  attr_reader :app_yaml_path
  attr_reader :project_id
  attr_reader :project_id_for_display
  attr_reader :project_id_for_example
  attr_reader :service_name
  attr_reader :env_variables
  attr_reader :cloud_sql_instances
  attr_reader :build_scripts
  attr_reader :runtime_config
  attr_reader :raw_entrypoint
  attr_reader :entrypoint
  attr_reader :install_packages
  attr_reader :ruby_version
  attr_reader :has_gemfile

  def initialize workspace_dir, argument_app_yaml
    @workspace_dir = workspace_dir
    @argument_app_yaml = argument_app_yaml
    init_app_config  # Must be called first
    init_project_id
    init_env_variables
    init_packages
    init_ruby_config
    init_cloud_sql_instances
    init_entrypoint
    init_build_scripts  # Must be called after init_entrypoint
  end

  private

  def init_app_config
    app_yaml_path = @argument_app_yaml || DEFAULT_APP_YAML_PATH
    @app_yaml_path = ::ENV["GAE_APPLICATION_YAML_PATH"] || app_yaml_path
    config_file = "#{@workspace_dir}/#{@app_yaml_path}"
    begin
      @app_config = ::Psych.load_file config_file
    rescue
      raise ::AppConfig::Error,
        "Could not read app engine config file: #{config_file.inspect}"
    end
    @runtime_config = @app_config["runtime_config"] || {}
    @beta_settings = @app_config["beta_settings"] || {}
    @service_name = @app_config["service"] || DEFAULT_SERVICE_NAME
  end

  def init_project_id
    @project_id = ::ENV["PROJECT_ID"]
    unless @project_id
      http = ::Net::HTTP.new "169.254.169.254",
                             open_timeout: 0.1, read_timeout: 0.1
      begin
        resp = http.get "/computeMetadata/v1/project/project-id",
                        {"Metadata-Flavor" => "Google"}
        @project_id = resp.body if resp.code == "200"
        http.finish
      rescue ::StandardError
      end
    end
    @project_id_for_display = @project_id || "(unknown)"
    @project_id_for_example = @project_id || "my-project-id"
  end

  def init_env_variables
    @env_variables = {}
    (@app_config["env_variables"] || {}).each do |k, v|
      if k !~ %r{\A[a-zA-Z]\w*\z}
        raise ::AppConfig::Error,
          "Illegal environment variable name: #{k.inspect}"
      end
      @env_variables[k.to_s] = v.to_s
    end
  end

  def init_build_scripts
    raw_build_scripts = @runtime_config["build"]
    if raw_build_scripts && @runtime_config["dotenv_config"]
      raise ::AppConfig::Error,
        "The `dotenv_config` setting conflicts with the `build` setting." +
        " If you want to build a dotenv file in your list of custom build" +
        " steps, try adding the build step: `gem install rcloadenv && rbenv " +
        " rehash && rcloadenv my-config-name > .env`"
    end
    @build_scripts = raw_build_scripts ?
        Array(raw_build_scripts) : default_build_scripts
    @build_scripts.each do |script|
      if script.include? "\n"
        raise ::AppConfig::Error,
          "Illegal newline in build command: #{script.inspect}"
      end
    end
  end

  def default_build_scripts
    [dotenv_from_rc_script, rails_asset_precompile_script].compact
  end

  def rails_asset_precompile_script
    return nil if !::File.directory?("#{@workspace_dir}/app/assets") ||
        !::File.file?("#{@workspace_dir}/config/application.rb")

    script = if @entrypoint =~ /(rcloadenv\s.+\s--\s)/
      "bundle exec #{$1}rake assets:precompile || true"
    else
      "bundle exec rake assets:precompile || true"
    end
    unless @cloud_sql_instances.empty?
      script = "access_cloud_sql --lenient && #{script}"
    end
    script
  end

  def dotenv_from_rc_script
    config_name = @runtime_config["dotenv_config"].to_s
    return nil if config_name.empty?
    "gem install rcloadenv && rbenv rehash && rcloadenv #{config_name} >> .env"
  end

  def init_cloud_sql_instances
    @cloud_sql_instances = Array(@beta_settings["cloud_sql_instances"]).
      flat_map{ |a| a.split(",") }
    @cloud_sql_instances.each do |name|
      if name !~ %r{\A[\w:.-]+\z}
        raise ::AppConfig::Error,
          "Illegal cloud sql instance name: #{name.inspect}"
      end
    end
  end

  def init_entrypoint
    @raw_entrypoint =
        @runtime_config["entrypoint"] ||
        @app_config["entrypoint"]
    if !@raw_entrypoint && ::File.readable?("#{@workspace_dir}/config.ru")
      @raw_entrypoint = DEFAULT_RACK_ENTRYPOINT
    end
    unless @raw_entrypoint
      raise ::AppConfig::Error,
        "Please specify an entrypoint in the App Engine configuration"
    end
    if @raw_entrypoint.include? "\n"
      raise ::AppConfig::Error,
        "Illegal newline in entrypoint: #{@raw_entrypoint.inspect}"
    end
    @entrypoint = decorate_entrypoint @raw_entrypoint
  end

  # Prepare entrypoint for rendering into the dockerfile.
  # If the provided entrypoint is an array, render it in exec format.
  # If the provided entrypoint is a string, we have to render it in shell
  # format. Now, we'd like to prepend "exec" so signals get caught properly.
  # However, there are some edge cases that we omit for safety.
  def decorate_entrypoint entrypoint
    return ::JSON.generate entrypoint if entrypoint.is_a? Array
    return entrypoint if entrypoint.start_with? "exec "
    return entrypoint if entrypoint =~ /;|&&|\|/
    return entrypoint if entrypoint =~ /^\w+=/
    "exec #{entrypoint}"
  end

  def init_packages
    @install_packages = Array(
      @runtime_config["packages"] || @app_config["packages"]
    )
    @install_packages.each do |pkg|
      if pkg !~ %r{\A[\w.-]+\z}
        raise ::AppConfig::Error, "Illegal debian package name: #{pkg.inspect}"
      end
    end
  end

  def init_ruby_config
    @ruby_version = ::File.read("#{@workspace_dir}/.ruby-version") rescue ''
    @ruby_version.strip!
    if @ruby_version == ""
      result = ::Dir.chdir(@workspace_dir) { `bundle platform --ruby` }
      if result.strip =~ %r{^ruby (\d+\.\d+\.\d+)$}
        @ruby_version = $1
      end
    end
    if @ruby_version =~ %r{\Aruby-(\d+\.\d+\.[\w.-]+)\z}
      @ruby_version = $1
    end
    unless @ruby_version.empty? || @ruby_version =~ %r{\A\d+\.\d+\.[\w.-]+\z}
      raise ::AppConfig::Error, "Illegal ruby version: #{@ruby_version.inspect}"
    end
    @has_gemfile = ::File.readable?("#{@workspace_dir}/Gemfile.lock") ||
        ::File.readable?("#{@workspace_dir}/gems.locked")
  end
end
