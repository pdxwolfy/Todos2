#!/usr/bin/env ruby
# Copyright (c) 2016 Launch School
# frozen_string_literal: true

require 'sinatra'
require 'sinatra/content_for'
require 'sinatra/reloader' if development?
require 'tilt/erubis'

LIST_CREATED = 'The list has been created.'
LIST_DELETED = 'The list has been deleted.'
LIST_NAME_SIZE_ERROR = 'The list name must be between 1 and 100 characters.'
LIST_NAME_UNIQUE_ERROR = 'The list name must be unique.'
LIST_UPDATED = 'The list has been been updated.'
SECRET_KEY = 'Four' # score and seven years ag0 or so.'
TODO_ALL_COMPLETED = 'All todo items are complete.'
TODO_COMPLETED = 'The todo has been completed.'
TODO_CREATED = 'The todo has been created.'
TODO_DELETED = 'The todo has been deleted.'
TODO_REOPENED = 'The todo has been reopened.'
TODO_TEXT_SIZE_ERROR = 'The todo text must be between 1 and 100 characters.'

configure do
  enable :sessions
  set :erb, escape_html: true
  set :session_secret, SECRET_KEY
end

helpers do
  def count_all_todos(list = @list)
    list[:todos].size
  end

  def count_open_todos(list = @list)
    list[:todos].count { |todo| !todo[:completed] }
  end

  def list_class(list = @list)
    'complete' if list_complete?(list)
  end

  def list_complete?(list = @list)
    count_all_todos(list) > 0 && count_open_todos(list) == 0
  end

  def lists_in_sequence(&generator)
    self.class.sort(@lists, generator) { |list| list_complete?(list) }
  end

  # List name to display to user in input fields
  def list_name_value(list = @list)
    (params && params[:list_name]) || (list && list[:name]) || ''
  end

  def todo_class(todo = @todo)
    'complete' if todo_complete?(todo)
  end

  # :reek:UtilityFunction
  def todo_complete?(todo = @todo)
    todo[:completed]
  end

  def todos_in_sequence(todos = @todos, &generator)
    self.class.sort(todos, generator) { |todo| todo_complete?(todo) }
  end

  #----------------------------------------------------------------------------
  # These class methods should be treated as private

  def self.sort(items, generator)
    items.each_with_index
         .sort_by { |item, _| yield(item) ? 1 : 0 }
         .each(&generator)
  end
end

HAS_LIST_ID_AND_TODO_ID = %r{^ /lists /([^/]+) /todos /([^/]+) (?:/.*)? \Z}x
HAS_LIST_ID_MAYBE       = %r{^ /lists /([^/]+) (?:/[^/]+)? \Z}x

before do
  session[:lists] ||= []
  init_for_all
end

# /lists/:list_id/todos/:todo_id/stuff
# /lists/:list_id/todos/:todo_id
before HAS_LIST_ID_AND_TODO_ID do |list_id, todo_id|
  init_for_todos(list_id, todo_id)
end

# /lists/:list_id/stuff
# /lists/:list_id
# /lists/new
before HAS_LIST_ID_MAYBE do |list_id|
  init_for_lists(list_id) unless list_id == 'new'
end

# Home page
get '/' do
  redirect '/lists'
end

# View list of lists
get '/lists' do
  erb :lists, layout: :layout
end

# Render the new list form
get '/lists/new' do
  erb :new_list, layout: :layout
end

# View a single list and let user create new todo items
get %r{^ /lists/\d+ \Z}x do
  erb :list, layout: :layout
end

# Edit an existing todo list
get %r{^ /lists/\d+/edit \Z}x do
  @list_name = @list[:name]
  erb :edit_list, layout: :layout
end

# Create a new list
post '/lists' do
  list_name = params[:list_name].strip
  error = validate_list_name(list_name)
  if error
    session[:error] = error
    erb :new_list, layout: :layout
    halt
  end

  session[:lists] << { name: list_name, todos: [] }
  session[:success] = LIST_CREATED
  redirect '/lists'
end

# Update an existing todo list
post %r{^ /lists/\d+ \Z}x do
  new_list_name = params[:list_name].strip

  error = (new_list_name == @list[:name]) || validate_list_name(new_list_name)
  if error
    session[:error] = error
    erb :edit_list, layout: :layout
    halt
  end

  @list[:name] = new_list_name
  session[:success] = LIST_UPDATED
  redirect "/lists/#{@list_id}"
end

# Mark all todo items complete on this list
post %r{^ /lists/\d+/complete_all \Z}x do
  @todos.each { |todo| todo[:completed] = true }
  session[:success] = TODO_ALL_COMPLETED
  redirect "/lists/#{@list_id}"
end

# Delete an existing todo list
post %r{^ /lists/\d+/destroy \Z}x do
  session[:lists].delete_at(@list_id)
  return '/lists' if ajax?

  session[:success] = LIST_DELETED
  redirect '/lists'
end

# Create a new todo item.
post %r{^ /lists/\d+/todos \Z}x do
  todo = params[:todo].strip

  error = validate_todo(todo)
  if error
    session[:error] = error
    erb :list, layout: :layout
    halt
  end

  session[:lists][@list_id][:todos] << { name: todo, completed: false }
  session[:success] = TODO_CREATED
  redirect "/lists/#{@list_id}"
end

# Complete/reopen an existing todo item
post %r{^ /lists/\d+/todos/\d+ \Z}x do
  @todo[:completed] = (params[:completed] == 'true')
  session[:success] = @todo[:completed] ? TODO_COMPLETED : TODO_REOPENED
  redirect "/lists/#{@list_id}"
end

# Delete an existing todo item
post %r{^ /lists/\d+/todos/\d+/destroy \Z}x do
  @todos.delete_at(@todo_id)
  no_response if ajax?

  session[:success] = TODO_DELETED
  redirect "/lists/#{@list_id}"
end

#------------------------------------------------------------------------------
# Instance variable initializers and validators

def init_for_all
  @lists = session[:lists]
end

def init_for_lists(list_id)
  init_for_all
  @list_id = validated_list_id(list_id)
  @list    = @list_id && @lists[@list_id]
  @todos   = @list    && @list[:todos]
end

def init_for_todos(list_id, todo_id)
  init_for_lists(list_id)
  @todo_id = todo_id.to_i
  @todo    = @todo_id && @todos[@todo_id]
end

def validated_list_id(list_id_str)
  list_id = list_id_str.to_i
  return list_id if (0...@lists.size).cover?(list_id)

  session[:error] = 'The specified list was not found.'
  redirect '/lists'
  halt
end

#------------------------------------------------------------------------------
# Other helpers

def ajax?
  env['HTTP_X_REQUESTED_WITH'] == 'XMLHttpRequest'
end

def no_response
  status(204)
  halt
end

#------------------------------------------------------------------------------
# Validation routines

# :reek:UtilityFunction
def right_size?(item)
  item.size.between?(1, 100)
end

def name?(name)
  @lists.find { |list| name == list[:name] }
end

def validate_list_name(new_name)
  return LIST_NAME_SIZE_ERROR   unless right_size?(new_name)
  return LIST_NAME_UNIQUE_ERROR if name?(new_name)
end

# :reek:UtilityFunction
def validate_todo(todo)
  return TODO_TEXT_SIZE_ERROR unless right_size?(todo)
end
