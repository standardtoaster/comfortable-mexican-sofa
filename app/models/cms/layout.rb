class Cms::Layout < ActiveRecord::Base
  include Cms::Base
  
  cms_acts_as_tree
  cms_is_mirrored
  cms_has_revisions_for :content, :css, :js, :head

  attr_accessor :tags
  
  # -- Relationships --------------------------------------------------------
  belongs_to :site
  has_many :pages, :dependent => :nullify
  
  # -- Callbacks ------------------------------------------------------------
  before_validation :assign_label
  before_create :assign_position
  after_save    :clear_cached_page_content
  after_destroy :clear_cached_page_content
  
  # -- Validations ----------------------------------------------------------
  validates :site_id,
    :presence   => true
  validates :label,
    :presence   => true
  validates :identifier,
    :presence   => true,
    :uniqueness => { :scope => :site_id },
    :format     => { :with => /\A\w[a-z0-9_-]*\z/i }
    
  # -- Scopes ---------------------------------------------------------------
  default_scope -> { order('cms_layouts.position') }
  
  # -- Class Methods --------------------------------------------------------
  # Tree-like structure for layouts
  def self.options_for_select(site, layout = nil, current_layout = nil, depth = 0, spacer = '. . ')
    out = []
    [current_layout || site.layouts.roots].flatten.each do |l|
      next if layout == l
      out << [ "#{spacer*depth}#{l.label}", l.id ]
      l.children.each do |child|
        out += options_for_select(site, layout, child, depth + 1, spacer)
      end
    end
    return out.compact
  end
  
  # List of available application layouts
  def self.app_layouts_for_select
    Dir.glob(File.expand_path('app/views/layouts/**/*.html.*', Rails.root)).collect do |filename|
      filename.gsub!("#{File.expand_path('app/views/layouts', Rails.root)}/", '')
      filename.split('/').last[0...1] == '_' ? nil : filename.split('.').first
    end.compact.sort
  end

  # Creates layouts inheriting from application layouts, so that pages can choose a layout if none
  # exist.
  def self.create_layouts_from_application_layouts(site)
    Cms::Layout.app_layouts_for_select.each do |app_layout|
      logger.debug("Checking application layout: #{app_layout}.")
      layout_for_app_layout = Cms::Layout.where(identifier: app_layout,
                                                site_id: site.id)
                                           .first_or_create
      # logger.debug("Current layout ID: #{layout_for_app_layout.id}.")
      layout_for_app_layout.app_layout = app_layout
      layout_for_app_layout.label ||= app_layout.capitalize
      layout_for_app_layout.content ||= '{{ cms:page:content:text }}'
      layout_for_app_layout.save!
    end
  end
  
  # -- Instance Methods -----------------------------------------------------
  # magical merging tag is {cms:page:content} If parent layout has this tag
  # defined its content will be merged. If no such tag found, parent content
  # is ignored.
  def merged_content
    if parent
      regex = /\{\{\s*cms:page:content:?(?:(?::text)|(?::rich_text))?\s*\}\}/
      if parent.merged_content.match(regex)
        parent.merged_content.gsub(regex, content.to_s)
      else
        content.to_s
      end
    else
      content.to_s
    end
  end

  # Internal: Merge the head of this layout with the head of any parent
  # layouts, to produce a final concatenated layout.
  def merged_head(page)
    page.tags ||= []
    # This is a little inefficient as the most inner content will get
    # processed over and over.
    processed_head = ComfortableMexicanSofa::Tag.process_content(
      page,
      ComfortableMexicanSofa::Tag.sanitize_irb(head.to_s)
    )
    if parent
      parent.merged_head(page).concat(processed_head)
    else
      processed_head
    end
  end

  def css(force_reload = true)
    @css = force_reload ? nil : read_attribute(:css)
    @css ||= begin
      self.tags = [] # resetting
      ComfortableMexicanSofa::Tag.process_content(
        self,
        ComfortableMexicanSofa::Tag.sanitize_irb(read_attribute(:css))
      )
   end
  end
  
protected
  
  def assign_label
    self.label = self.label.blank?? self.identifier.try(:titleize) : self.label
  end
  
  def assign_position
    return if self.position.to_i > 0
    max = self.site.layouts.where(:parent_id => self.parent_id).maximum(:position)
    self.position = max ? max + 1 : 0
  end
  
  # Forcing page content reload
  def clear_cached_page_content
    Cms::Page.where(:id => self.pages.pluck(:id)).update_all(:content => nil)
    self.children.each{ |child_layout| child_layout.clear_cached_page_content }
  end
end
