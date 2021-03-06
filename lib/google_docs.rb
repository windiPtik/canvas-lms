#
# Copyright (C) 2011 Instructure, Inc.
#
# This file is part of Canvas.
#
# Canvas is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License as published by the Free
# Software Foundation, version 3 of the License.
#
# Canvas is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
# details.
#
# You should have received a copy of the GNU Affero General Public License along
# with this program. If not, see <http://www.gnu.org/licenses/>.
#

# See Google Docs API documentation here:
# http://code.google.com/apis/documents/docs/2.0/developers_guide_protocol.html
class GoogleDocs

  class NoTokenError < StandardError
    def initialize
      super("User does not have a valid Google Docs token")
    end
  end

  def initialize(user, session)
    @user = user
    @session = session
  end

  def retrieve_access_token
    consumer = GoogleDocs.consumer
    return nil unless consumer
    if @user
      service_token, service_secret = Rails.cache.fetch(['google_docs_tokens', @user].cache_key) do
        service = @user.user_services.find_by_service("google_docs")
        service && [service.token, service.secret]
      end
      raise NoTokenError unless service_token && service_secret
      access_token = OAuth::AccessToken.new(consumer, service_token, service_secret)
    else
      access_token = OAuth::AccessToken.new(consumer, @session[:oauth_gdocs_access_token_token], @session[:oauth_gdocs_access_token_secret])
    end
    access_token
  end

  def get_service_user(access_token)
    doc = create_doc("Temp Doc: #{Time.now.strftime("%d %b %Y, %I:%M %p")}", access_token)
    delete_doc(doc, access_token)
    service_user_id = doc.entry.authors[0].email rescue nil
    service_user_name = doc.entry.authors[0].email rescue nil
    return service_user_id, service_user_name
  end

  def self.get_access_token(oauth_request, oauth_verifier, session, user)
    consumer = GoogleDocs.consumer
    request_token = OAuth::RequestToken.new(consumer,
                                            session.delete(:oauth_google_docs_request_token_token),
                                            session.delete(:oauth_google_docs_request_token_secret))
    access_token = request_token.get_access_token(:oauth_verifier => oauth_verifier)
    google_docs = GoogleDocs.new(user, session)
    service_user_id, service_user_name = google_docs.get_service_user(access_token)
    session[:oauth_gdocs_access_token_token] = access_token.token
    session[:oauth_gdocs_access_token_secret] = access_token.secret
    if oauth_request.user
      UserService.register(
        :service => "google_docs",
        :access_token => access_token,
        :user => oauth_request.user,
        :service_domain => "google.com",
        :service_user_id => service_user_id,
        :service_user_name => service_user_name
      )
      oauth_request.destroy
      session.delete(:oauth_gdocs_access_token_token)
      session.delete(:oauth_gdocs_access_token_secret)
    end
    access_token
  end

  def self.request_token_url(return_to, session, user, host_with_port, oauth_callback)
    consumer = GoogleDocs.consumer
    request_token = consumer.get_request_token({ :oauth_callback => oauth_callback}, {:scope => "https://docs.google.com/feeds/ https://spreadsheets.google.com/feeds/"})
    session[:oauth_google_docs_request_token_token] = request_token.token
    session[:oauth_google_docs_request_token_secret] = request_token.secret
    OauthRequest.create(
      :service => 'google_docs',
      :token => request_token.token,
      :secret => request_token.secret,
      :user_secret => CanvasUuid::Uuid.generate(nil, 16),
      :return_url => return_to,
      :user => user,
      :original_host_with_port => host_with_port
    )
    request_token.authorize_url
  end


  def download(document_id)
    access_token = retrieve_access_token
    entry = fetch_list(access_token).entries.map{|e| GoogleDocEntry.new(e) }.find{|e| e.document_id == document_id}
    if entry
      response = access_token.get(entry.download_url)
      response = access_token.get(response['Location']) if response.is_a?(Net::HTTPFound)
      [response, entry.display_name, entry.extension]
    else
      [nil, nil, nil]
    end
  end

  class Folder
    attr_reader :name, :folders, :files

    def initialize(name, folders=[], files=[])
      @name = name
      # File objects are GoogleDocEntry objects
      @folders, @files = folders, files
    end

    def add_file(file)
      @files << file
    end

    def add_folder(folder)
      @folders << folder
    end

    def select(&block)
      Folder.new(@name,
        @folders.map{ |f| f.select(&block) }.select{ |f| !f.files.empty? },
        @files.select(&block))
    end

    def map(&block)
      @folders.map{ |f| f.map(&block) }.flatten +
        @files.map(&block)
    end

    def to_hash
      {
        "name" => @name,
        "folders" => @folders.map{ |sf| sf.to_hash },
        "files" => @files.map{ |f| f.to_hash }
      }
    end
  end

  def fetch_list(access_token)
    response = access_token.get('https://docs.google.com/feeds/documents/private/full')
    Atom::Feed.load_feed(response.body)
  end
  private :fetch_list

  def folderize_list(docs)
    root = Folder.new('/')
    folders = { nil => root }

    docs.entries.each do |entry|
      entry = GoogleDocEntry.new(entry)
      if !folders.has_key?(entry.folder)
        folder = Folder.new(entry.folder)
        root.add_folder folder
        folders[entry.folder] = folder
      else
        folder = folders[entry.folder]
      end
      folder.add_file entry
    end

    return root
  end
  private :folderize_list

  def list(access_token=nil)
    access_token ||= retrieve_access_token
    folderize_list(fetch_list(access_token))
  end
  private :list

  def list_with_extension_filter(extensions, access_token=nil)
    access_token ||= retrieve_access_token
    docs = list(access_token)
    if extensions && extensions.length > 0
      docs = docs.select{ |e| extensions.include?(e.extension) }
    end
    docs
  end

  def self.consumer(key = nil, secret = nil)
    if key.nil? || secret.nil?
      return nil if GoogleDocs.config.nil?
      key ||= GoogleDocs.config['api_key']
      secret ||= GoogleDocs.config['secret_key']
    end

    require 'oauth'
    require 'oauth/consumer'

    OAuth::Consumer.new(key, secret, {
      :site               => 'https://www.google.com',
      :request_token_path => '/accounts/OAuthGetRequestToken',
      :access_token_path  => '/accounts/OAuthGetAccessToken',
      :authorize_path     => '/accounts/OAuthAuthorizeToken',
      :signature_method   => 'HMAC-SHA1'
    })
  end

  class Google
    class Google::Batch
      class Google::Batch::Operation
        attr_accessor :type
        def initialize(operation_type="insert")
          self.type = operation_type
        end
        def to_xml(*opts)
          n = XML::Node.new("batch:operation")
          n['type'] = type
          n
        end
      end
    end

    class Google::GAcl
      class Google::GAcl::Role
        attr_accessor :role

        def initialize()
          self.role = "writer"
        end

        def to_xml(*opts)
          n = XML::Node.new("gAcl:role")
          n['value'] = role
          n
        end
      end

      class Google::GAcl::Scope
        attr_accessor :type, :value

        def initialize(email)
          self.type = "user"
          self.value = email
        end

        def to_xml(*opts)
          n = XML::Node.new("gAcl:scope")
          n['type'] = type
          n['value'] = value
          n
        end
      end
    end
  end

  class Entry < Atom::Entry
    namespace Atom::NAMESPACE
    element "id"
    element "batch:id"
    element "batch:operation", :class => Google::Batch::Operation
    element "gAcl:role", :class => Google::GAcl::Role
    element "gAcl:scope", :class => Google::GAcl::Scope
    elements :categories
    add_extension_namespace :batch, 'http://schemas.google.com/gdata/batch'
    add_extension_namespace :gAcl, 'http://schemas.google.com/acl/2007'
  end
  class Feed < Atom::Feed
    namespace Atom::NAMESPACE
    elements :entries
    elements :categories

    add_extension_namespace :batch, 'http://schemas.google.com/gdata/batch'
    add_extension_namespace :gAcl, 'http://schemas.google.com/acl/2007'
  end

  def create_doc(name, access_token=nil)
    access_token ||= retrieve_access_token
    url = "https://docs.google.com/feeds/documents/private/full"
    entry = Atom::Entry.new do |entry|
      entry.title = name
      entry.categories << Atom::Category.new do |category|
        category.scheme = "http://schemas.google.com/g/2005#kind"
        category.term = "http://schemas.google.com/docs/2007#document"
        category.label = "document"
      end
    end
    xml = entry.to_xml
    begin
      response = access_token.post(url, xml, {'Content-Type' => 'application/atom+xml'})
    rescue => e
      raise "Unable to post to Google API #{url}:\n#{xml}" +
            "\n\n(" + e.to_s + ")\n"
    end
    begin
      GoogleDocEntry.new(Atom::Entry.load_entry(response.body))
    rescue => e
      raise "Unable to load GoogleDocEntry from response: \n" + response.body + 
            "\n\n(" + e.to_s + ")\n"
    end
  end

  def delete_doc(entry, access_token = retrieve_access_token)
    access_token.delete(entry.edit_url, { 'GData-Version' => '2', 'If-Match' => '*' })
  end

  def acl_remove(document_id, users)
    access_token = retrieve_access_token
    url          = "https://docs.google.com/feeds/acl/private/full/#{document_id}/batch"

    Struct.new('UserStruct', :id, :gmail, :google_docs_address)
    users.each_with_index do |user, idx|
      if user.is_a? String
        users[idx] = Struct::UserStruct.new(user, user)
      end
    end

    request_feed = Feed.new do |feed|
      feed.categories << Atom::Category.new{|category|
        category.scheme = "http://schemas.google.com/g/2005#kind"
        category.term = "http://schemas.google.com/acl/2007#accessRule"
      }
      users.each do |user|
        next unless user_identifier = user.google_docs_address || user.gmail

        feed.entries << Entry.new do |entry|
          entry.id              = "https://docs.google.com/feeds/acl/private/full/#{CGI.escape(document_id)}/user%3A#{CGI.escape(user_identifier)}"
          entry.batch_operation = Google::Batch::Operation.new('delete')
          entry.gAcl_role       = Google::GAcl::Role.new
          entry.gAcl_scope      = Google::GAcl::Scope.new(user_identifier)
        end
      end
    end
    response = access_token.post(url, request_feed.to_xml, {'Content-Type' => 'application/atom+xml'})
    feed     = Atom::Feed.load_feed(response.body)
    res      = []

    feed.entries.each do |entry|
      user = users.to_a.find{|u| u.id == entry['http://schemas.google.com/gdata/batch', 'id'][0].to_i}
      res << user if user
    end

    res
  end


  # Public: Add users to a Google Doc ACL list.
  #
  # document_id - The id of the Google Doc to add users to.
  # users - An array of user objects.
  # domain - The string domain to restrict additions to (e.g. "example.com").
  #   Accounts not on this domain will be ignored.
  #
  # Returns nothing.
  def acl_add(document_id, users, domain = nil)
    access_token  = retrieve_access_token
    url           = "https://docs.google.com/feeds/acl/private/full/#{document_id}/batch"
    domain_regex  = domain ? %r{@#{domain}$} : /./
    allowed_users = []

    user_added = false
    request_feed = Feed.new do |feed|
      feed.categories << Atom::Category.new do |category|
        category.scheme = "http://schemas.google.com/g/2005#kind"
        category.term   = "http://schemas.google.com/acl/2007#accessRule"
      end

      allowed_users = users.select do |user|
        address = user.google_docs_address || user.gmail
        address.try(:match, domain_regex)
      end

      allowed_users.each do |user|
        user_added = true
        feed.entries << user_feed_entry(user)
      end
    end

    return unless user_added

    response = access_token.post(url, request_feed.to_xml, {'Content-Type' => 'application/atom+xml' })
    feed = Atom::Feed.load_feed(response.body)
    feed.entries.inject([]) do |response, entry|
      user = allowed_users.find do |u|
        u.id == entry['http://schemas.google.com/gdata/batch', 'id'][0].to_i
      end
      response << user if user
      response
    end
  end

  def user_feed_entry(user)
    Entry.new do |entry|
      entry.batch_id        = user.id
      entry.batch_operation = Google::Batch::Operation.new
      entry.gAcl_role       = Google::GAcl::Role.new
      entry.gAcl_scope      = Google::GAcl::Scope.new(user.google_docs_address || user.gmail)
    end
  end
  private :user_feed_entry

  def verify_access_token
    access_token = retrieve_access_token
    access_token.head("https://www.google.com/accounts/AuthSubTokenInfo").is_a? Net::HTTPSuccess
  end

  def self.config_check(settings)
    consumer = GoogleDocs.consumer(settings[:api_key], settings[:secret_key])
    token = consumer.get_request_token({}, {:scope => "https://docs.google.com/feeds/"}) rescue nil
    token ? nil : "Configuration check failed, please check your settings"
  end

  def self.config
    Canvas::Plugin.find(:google_docs).try(:settings) || Setting.from_config('google_docs')
  end
end
