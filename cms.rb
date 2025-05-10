#!/usr/bin/env ruby
# Copyright (c) 2016 Pete Hanson
# frozen_string_literal: true

require 'addressable/uri'
require 'bcrypt'
require 'pathname'
require 'redcarpet'
require 'sinatra'
require 'sinatra/content_for'
require 'sinatra/reloader' if development?
require 'tilt/erubis'
require 'uri'
require 'yaml'

# :reek:UtilityFunction
# Must precede 'messages'
def testing?
  ENV['RACK_ENV'] == 'test'
end

require_relative 'messages'

# HTTP status codes
module HTTPStatus
  UNPROCESSABLE = 422
end.freeze

# Session info
module Session
  SECRET_KEY = 'Wh@t c4n u 2 4 m3?'
end.freeze

# test mode definitions
if testing?
  module TestMode
    EMPTY_PAGE = 'This page intentionally left blank'

    # Admin account info
    module Admin
      USERNAME = 'admin'
      PASSWORD = 'secret'
    end

    module Route
      LAYOUT            = '/layout'
      SESSION_ATTRIBUTE = '/session/attribute'
    end
  end
end

# Routes
module Route
  INDEX          = '/'
  FILE_DELETE    = '/file/delete'
  FILE_DUPLICATE = '/file/duplicate'
  FILE_EDIT      = '/file/edit'
  FILE_NEW       = '/file/new'
  FILE_VIEW      = '/file'
  USERS_SIGNIN   = '/users/signin'
  USERS_SIGNOUT  = '/users/signout'
  USERS_SIGNUP   = '/users/signup'

  # Route groupings
  INDEX_AND_FILE = '(^ / $) | (^ /file (/.*)? $)'

  # These routes do not require a login
  safe = [INDEX, FILE_VIEW, USERS_SIGNIN, USERS_SIGNOUT, USERS_SIGNUP]
  if testing?
    safe << TestMode::Route::LAYOUT << TestMode::Route::SESSION_ATTRIBUTE
  end

  SAFE = Set.new(safe).freeze
end.freeze

configure do
  enable :sessions
  set :session_secret, Session::SECRET_KEY
  set :erb, escape_html: true
end

helpers do
  # :reek:UtilityFunction
  def escape string
    Addressable::URI.encode_component string
  end

  # :reek:UtilityFunction
  def url url_path, parameters
    query_string = parameters.map { |key, value| "#{key}=#{escape value}" }
                             .join '&'
    "#{url_path}?#{query_string}"
  end
end

before do
  puts "before: #{self}"
  class << self
    puts "<<: #{self}"
    def xyzzy
      @x = 3
      puts "xyzzy: #{self}"
    end
    @@xx = 5
    puts "<<<<: #{self} #{@@xx}"
  end
  xyzzy

  @message = Messages.new self
  return if logged_in?
  return if Route::SAFE.include? request.path_info
  redirect_with Route::INDEX, error: @message[:must_be_signed_in]
end

before Route::INDEX_AND_FILE do
  @file_name = params[:name] || ''
  @path_name = File.join data_path.to_s, @file_name if @file_name
end

get Route::INDEX do
  @files = select_files.map { |path| path.basename.to_path }
  fetch :documents
end

post Route::FILE_DELETE do
  error_id = delete_file
  flash =
    if error_id
      { error: error_id }
    else
      { message: @message[:file_deleted] }
    end

  redirect_with Route::INDEX, flash
end

get Route::FILE_EDIT do
  error_id = load_file
  redirect_with Route::INDEX, error: error_id if error_id
  fetch :edit
end

post Route::FILE_EDIT do
  error_id = save_file params[:content]
  flash =
    if error_id
      { error: error_id }
    else
      { message: @message[:file_updated] }
    end

  redirect_with Route::INDEX, flash
end

get Route::FILE_NEW do
  fetch :new
end

post Route::FILE_NEW do
  error_id = create_file
  redirect_with Route::INDEX, message: @message[:created_file] unless error_id
  fetch_with :new, error: error_id
end

get Route::FILE_DUPLICATE do
  error_id = load_file
  redirect_with Route::INDEX, error: error_id if error_id

  @original_file_name = @file_name
  fetch :duplicate
end

post Route::FILE_DUPLICATE do
  @original_file_name = params[:original] || ''
  original_path_name = File.join data_path.to_s, @original_file_name

  error_id = duplicate_file original_path_name
  if error_id
    fetch_with :duplicate, error: error_id
  else
    redirect_with Route::INDEX, message: @message[:duplicate_created]
  end
end

get Route::FILE_VIEW do
  error_id = load_file
  redirect_with Route::INDEX, error: error_id if error_id
  render_file
end

get Route::USERS_SIGNIN do
  fetch :login
end

post Route::USERS_SIGNIN do
  @username = params[:username] || ''
  password = params[:password] || ''
  params.delete :password

  if authenticate? @username, password
    redirect_with Route::INDEX, message: @message[:welcome], username: @username
  else
    authentication_failure
  end
end

post Route::USERS_SIGNOUT do
  session.delete :username
  redirect_with Route::INDEX, message: @message[:signed_out]
end

get Route::USERS_SIGNUP do
  fetch :signup
end

post Route::USERS_SIGNUP do
  @username = params[:username]
  password = params[:password]
  params.delete :password

  error_ids = create_account @username, password
  if error_ids
    signup_failure error_ids
  else
    redirect_with Route::USERS_SIGNIN, message: @message[:account_created]
  end
end

#------------------------------------------------------------------------------
# Test helpers

if testing?
  # test layout.erb
  get TestMode::Route::LAYOUT do
    erb TestMode::EMPTY_PAGE, layout: :layout
  end

  # set session data
  post TestMode::Route::SESSION_ATTRIBUTE do
    session.merge! params
  end

  def session_values hash_args = {}
    post TestMode::Route::SESSION_ATTRIBUTE, hash_args
  end
end

#------------------------------------------------------------------------------
# Route helpers

def errno_as_message path, errno_exception
  case errno_exception
  when Errno::EEXIST then get_message :file_exists, path
  when Errno::ENOENT then get_message :could_not_create, path
  else
    error_id = errno_exception.message.sub(/ @ .*/, '')
    "#{strip_data_path path}: #{error_id}."
  end
end

def fetch source
  erb source, layout: :layout
end

def fetch_with source, session_args
  if session_args
    %i(error message).each do |type|
      items = session_args[type]
      session_args[type] = [items] unless items.respond_to? :each
    end

    session.merge! session_args
  end

  fetch source
end

def get_message id, path
  @message.fetch id, file_name: strip_data_path(path)
end

def redirect_with route, session_args = {}
  session.merge! session_args if session_args
  redirect route
end

#------------------------------------------------------------------------------
# Authentication methods

def add_user username, password
  File.open(auth_file, 'a') do |file|
    file.puts "#{username}: '#{BCrypt::Password.create(password)}'"
  end
end

def auth_load
  YAML.load_file auth_file.to_s
end

def auth_file
  Pathname(__FILE__) + '..' + auth_path + 'users.yaml'
end

def auth_path
  testing? ? 'auth-test' : 'auth'
end

def authenticate? username, raw_password
  encrypted_password = auth_load[username] or return false
  $stderr.puts encrypted_password.inspect
  $stderr.puts raw_password.inspect
  $stderr.puts BCrypt::Password.new(encrypted_password).inspect
  BCrypt::Password.new(encrypted_password) == raw_password
end

def authentication_failure
  status HTTPStatus::UNPROCESSABLE
  fetch_with :login, error: @message[:invalid_credentials]
end

def create_account username, password
  error_ids = [validate_username(username), validate_password(password)]
  error_ids.compact!
  return error_ids unless error_ids.empty?

  add_user username, password
end

def in_use? username
  auth_load.key? username
end

def logged_in?
  !(!session[:username])
end

def signup_failure error_ids
  status HTTPStatus::UNPROCESSABLE
  fetch_with :signup, error: @message.fetch_all(error_ids)
end

def validate_username username
  return :missing_username if username.empty?
  return :username_in_use if in_use? username
end

# :reek:UtilityFunction
def validate_password password
  return :missing_password if password.empty?
  return :password_too_short if password.size < 8
end

#------------------------------------------------------------------------------
# File and path helpers

def create_file path = @path_name, content: ''
  return get_message :enter_file_name, path if missing_file_name? path
  return get_message :unknown_file_type, path unless known_extension? path
  trap_system_call_error path do
    IO.write path, content, mode: (File::WRONLY | File::CREAT | File::EXCL)
  end
end

def data_path
  path = Pathname(__FILE__) + '..'
  path += testing? ? 'test-data' : 'data'
  path.to_path
end

def delete_file path = @path_name
  process_file(path) { File.delete path }
end

def duplicate_file original_path, new_path = @path_name
  error_id = load_file original_path
  return error_id if error_id

  create_file new_path, content: @content
end

# :reek:UtilityFunction
def known_extension? path
  %w(.md .txt).include? File.extname(path.to_s)
end

def load_file path = @path_name
  process_file path do
    @content = File.read path
    nil
  end
end

def missing_file_name? path
  strip_data_path(path).empty?
end

def process_file path, &action
  return get_message :missing_file_name, path if missing_file_name? path
  return get_message :unknown_file_type, path unless known_extension? path
  return get_message :does_not_exist, path unless File.exist? path
  trap_system_call_error(path, &action)
end

def render_file path = @path_name
  renderers = { '.md' => :render_markdown }
  extension = File.extname path
  renderer = renderers[extension] || :render_text
  __send__ renderer
end

def render_markdown
  markdown = Redcarpet::Markdown.new Redcarpet::Render::HTML
  rendered_file = markdown.render @content
  fetch rendered_file
end

def render_text
  headers 'Content-Type' => 'text/plain'
  @content
end

def save_file content, path = @path_name
  process_file(path) { File.write path, content }
end

def select_files
  Pathname(data_path).children.select do |path|
    path.readable? && path.file? && known_extension?(path)
  end
end

def strip_data_path path
  escaped_data_path = Regexp.escape File.join(data_path, '')
  pattern = Regexp.new '\A' + escaped_data_path
  path.sub pattern, ''
end

def trap_system_call_error path
  yield
  nil
rescue SystemCallError => exception
  errno_as_message path, exception
end
