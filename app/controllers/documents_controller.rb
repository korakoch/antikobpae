require 'fileutils'
require 'iconv'

class DocumentsController < ApplicationController
  before_filter :require_existing_file, :only => [:show, :edit, :update, :destroy, :download, :image]
  before_filter :require_html_content, :only => [:show, :edit, :download]
  before_filter :require_existing_target_folder, :only => [:new, :create]
  #before_filter :require_existing_target_scan, :only => [:new, :create]

  before_filter :require_create_permission, :only => [:new, :create]
  before_filter :require_read_permission, :only => :show
  before_filter :require_update_permission, :only => [:edit, :update]
  before_filter :require_delete_permission, :only => :destroy

  # @document and @folder are set in require_existing_file
  def show
  end
  
  def xmlpipe
    @records = Document.all
    render :xml => @records.to_xml
  end
  
  def image
    render :xml => File.open([File.dirname(@document.attachment.path), 'images', 1].join('/'), 'r').read 
  end

  def typeahead 
    results = Content.search params[:query], 
      :rank_mode => :bm25,
      :field_weights => {
        :name => 10,
        :attachment_file_name => 6,
        :text => 3
      }, 
      :page => 1, 
      :per_page => 10
    respond_to do |format|
      format.json  {render :json => results.map {|result| result.document }}
    end
  end

  def search 
    results = Content.search params[:query], 
      :rank_mode => :bm25,
      :field_weights => {
        :name => 10,
        :attachment_file_name => 6,
        :text => 3
      }, 
      :page => params[:page], 
      :per_page => 50
    @documents = results.map {|result| result.document}
    @documents = @documents.paginate(
      :page => results.current_page, 
      :per_page => results.per_page, 
      :total_entries => results.total_entries
    )
  end

  def download
  	respond_to do |format|
  	  format.orig do
  	  	send_file [@document.attachment.path,@document.attachment_file_type].join('.'), :filename => [@document.name,@document.attachment_file_type].join('.')
  	  end
  	  format.html do
  	  	send_file [@document.attachment.path,'html'].join('.'), :filename => [@document.name,'html'].join('.')
  	  end
  	  format.text do
  	  	send_file [@document.attachment.path,'txt'].join('.'), :filename => [@document.name,'txt'].join('.')
  	  end
  	  format.pdf do
  	    render :pdf => @document.name, :wkhtmltopdf => AppConfig.wkhtmltopdf_bin
  	  end
  	end
    #send_file @document.attachment.path, :filename => @document.attachment_file_name
  end
  
  # @target_folder is set in require_existing_target_folder
  def new
    @document = @target_folder.documents.build(:content => Content.new(:text => I18n.t(:document_content)))
    @document[:name] = nil
  end

  # @target_folder is set in require_existing_target_folder
  def create
    
    newparams = coerce(params) 

    @document = @target_folder.documents.build(newparams[:document])  

    @document.status = 1
    @document.from = @target_folder.parent == current_user.scans_folder ? 'scan' : 'file'
    @document.user = current_user

    case params[:from]
    when 'upload' 
      if @document.name.blank? && !@document.attachment_file_name.blank?
        @document.name = File.basename(@document.attachment_file_name, File.extname(@document.attachment_file_name)).sub(/_/,' ')  
      end
    when 'scratch'
      tempfile = Tempfile.new('document', Rails.root.join('tmp') )
      tempfile.write params[:content][:text]
      tempfile.close
      @document.attachment = File.open(tempfile.path)
      @document.attachment_file_name = [@document.name,'file'].join('.')
      @document.content = nil
    when 'webpage'
      require 'open-uri'
      @document.attachment_file_type = 'html'
      uri = URI.parse(URI::escape(@document.attachment_file_name))
      @document.name = [uri.host,'-',SecureRandom.hex(6)].join 
    end
    
    if @document.save!
      flash[:notice] = I18n.t(:document_create_success)
      respond_to do |format| 
        format.html { redirect_to folder_url(@target_folder) } 
        format.json  { render :json => { :result => 'success', :upload => document_path(@document) } } 
      end	
    else
    	@document[:content] = params[:document][:content]
      @document[:name] = params[:document][:name]
      flash[:error] = I18n.t(:document_create_fail)
      respond_to do |format| 
        format.html { render :action => 'new' } 
        format.json  { render :json => { :result => 'failed' } } 
      end
    end  
      
	#end unless params[:document].nil?
    #redirect_to fredit_path(:file => @path)
  #rescue ConversionError
  #	redirect_to folder_url(@target_folder), :alert => t(:conversion_problem, :type => t(:this_file))
  end

  # @document and @folder are set in require_existing_file
  def edit
  end

  # @document and @folder are set in require_existing_file
  def update

  	File.open(@document.attachment.path, 'wb') do |f|
      f.puts params[:content][:text]
    end

    params[:document].delete(:name) if params[:document][:name].empty?
    params[:document][:status] = 1
  	params[:document][:user] = current_user
 
    if @document.update_attributes(params[:document])
      redirect_to edit_document_url(@document), :notice => t(:your_changes_were_saved)
    else
      render :action => 'edit'
    end
  end

  # @document and @folder are set in require_existing_file
  def destroy
    @document.destroy
    redirect_to folder_url(@folder)
  end

  def coerce(params) 
    if params[:document].nil? 
      h = Hash.new 
      h[:document] = Hash.new 
      h[:document][:attachment] = params[:file] 
      h[:document][:name] = params[:name] 
      h[:document][:text_only] = params[:document_text_only]
      #h[:upload][:data].content_type =  MIME::Types.type_for(h[:upload][:data].original_filename).to_s 
      h 
    else 
      params
    end 
  end

  private

  def require_existing_file
    @document = Document.find(params[:id])
    @folder = @document.folder
  rescue ActiveRecord::RecordNotFound
    redirect_to folder_url(Folder.root), :alert => t(:already_deleted, :type => t(:this_file))
  end
  
  def require_html_content
    if File.exists? [@document.attachment.path,'html'].join('.')
      @document.content = Content.new(:text => File.open([@document.attachment.path,'html'].join('.'), 'r:UTF-8').read) 
    else @document.content = Content.new(:text => "
      <div class=\"hero-unit\"> 
      <h1>Wait !</h1> 
      <p>Your file is being queued for conversion. Please wait for a moment. 
      This can take while, espacially if the file is big</p> 
      <p> 
      <a href=\"#{folder_url(@document.folder)}\" class=\"btn btn-primary btn-large\"> 
        Take me back 
      </a> 
      </p> 
      </div>")
    end
  rescue Errno::ENOENT
    redirect_to folder_url(@folder), :alert => t(:already_deleted, :type => t(:this_content)+[@document.attachment.path,'html'].join('.'))
  end
end
