# Copyright (c) 2014-2016, VMware, Inc. All Rights Reserved.
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights to
# use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
# of the Software, and to permit persons to whom the Software is furnished to do
# so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

require 'link_preview/uri'
require 'link_preview/parser'
require 'link_preview/http_crawler'
require 'link_preview/null_crawler'

require 'active_support/core_ext/object'

module LinkPreview
  class Content
    PROPERTIES = [
      :title,
      :description,
      :favicon,
      :site_name,
      :site_url,
      :image_url,
      :image_data,
      :image_content_type,
      :image_file_name,
      :content_url,
      :content_type,
      :content_width,
      :content_height,
      :page_content_type
    ].freeze

    SOURCES = [:headers, :initial, :image, :oembed, :opengraph_embed, :opengraph, :html].freeze

    SOURCE_PROPERTIES_TABLE =
      {
        oembed: {
          site_name: :provider_name,
          site_url: :provider_url,
          image_url: :thumbnail_url
        },
        opengraph: {
          image_url: [:image_secure_url, :image_url],
          content_url: [:video_secure_url, :video_url],
          content_type: :video_type,
          content_width: :video_width,
          content_height: :video_height
        },
        opengraph_embed: {
          image_url: [:image_secure_url, :image_url],
          content_url: [:video_secure_url, :video_url],
          content_type: :video_type,
          content_width: :video_width,
          content_height: :video_height
        }
      }.freeze

    PROPERTIES_SOURCE_TABLE =
      Hash.new { |h, k| h[k] = {} }.tap do |reverse_property_table|
        SOURCE_PROPERTIES_TABLE.each do |source, table|
          table.invert.each_pair do |keys, val|
            Array.wrap(keys).each do |key|
              reverse_property_table[source][key] = val
            end
          end
        end
      end

    def initialize(config, content_uri, options = {}, sources = {})
      @config = config
      @content_uri = content_uri
      @options = options
      @sources = Hash.new { |h, k| h[k] = {} }
      crawler.enqueue!(@content_uri)

      add_source_properties!(sources)
    end

    # @return [String] permalink URL of resource
    def url
      @content_uri
    end

    PROPERTIES.each do |property|
      define_method(property) do
        extract(property)
      end
    end

    # @return [Boolean] true of at least related content URI has been successfully fetched
    def found?
      extract_all
      crawler.success?
    end

    # @return [Boolean] true of at least one content property is present
    def empty?
      extract_all
      SOURCES.none? do |source|
        @sources[source].any?(&:present?)
      end
    end

    attr_reader :sources

    def as_oembed
      if content_type_embed? || content_type_iframe? || content_type_video? || content_type_flash?
        @sources[:oembed].reverse_merge(as_oembed_video)
      elsif content_type_image?
        @sources[:oembed].reverse_merge(as_oembed_image)
      else
        @sources[:oembed].reverse_merge(as_oembed_link)
      end
    end

    protected

    def crawler
      @crawler ||= crawler_class.new(@config, @options)
    end

    def parser
      @parser ||= LinkPreview::Parser.new(@config, @options)
    end

    def parsed_url
      LinkPreview::URI.parse(url, @options)
    end

    def default_property(property)
      send("default_#{property}") if respond_to?("default_#{property}", true)
    end

    # called via default_property
    def default_title
      parsed_url.for_display.to_s
    end

    # called via default_property
    def default_site_name
      parsed_url.host
    end

    # called via default_property
    def default_site_url
      return unless parsed_url.scheme && parsed_url.host
      "#{parsed_url.scheme}://#{parsed_url.host}"
    end

    def normalize_property(property, value)
      if respond_to?("normalize_#{property}", true)
        send("normalize_#{property}", value)
      else
        normalize_generic(property, value)
      end
    end

    def normalize_generic(property, value)
      case value
      when String
        strip_html(value.strip)
      when Array
        value.compact.map { |elem| normalize_property(property, elem) }
      else
        value
      end
    end

    # called via normalize_property
    def normalize_image_url(partial_image_url)
      return unless partial_image_url
      parsed_partial_image_url = LinkPreview::URI.parse(partial_image_url, @options)
      parsed_absolute_image_url = parsed_partial_image_url.to_absolute(@content_uri)
      parsed_absolute_image_url.to_s.tap do |absolute_image_url|
        crawler.enqueue!(absolute_image_url, :image)
      end
    end

    # called via normalize_property
    def normalize_url(partial_url)
      return unless partial_url
      partial_unencoded_url = LinkPreview::URI.unescape(partial_url)
      parsed_partial_url = LinkPreview::URI.parse(partial_unencoded_url, @options)
      parsed_absolute_url = parsed_partial_url.to_absolute(@content_uri)
      crawler.enqueue!(parsed_absolute_url, :html)
      parsed_absolute_url.for_display.to_s
    end

    # called via normalize_property
    def normalize_content_url(content_url)
      return unless content_url
      LinkPreview::URI.safe_escape(content_url).to_s
    end

    # called via normalize_property
    def normalize_title(title)
      CGI.unescapeHTML(title)
    end

    # called via normalize_property
    def normalize_html(html)
      html
    end

    def get_property(property)
      SOURCES.map do |source|
        @sources[source][property_alias(source, property)]
      end.compact.first || default_property(property)
    end

    def property?(property)
      SOURCES.map do |source|
        @sources[source][property_alias(source, property)]
      end.any?(&:present?)
    end

    def property_alias(source, property)
      property_aliases(source, property).detect { |p| @sources[source].key?(p) }
    end

    def property_aliases(source, property)
      Array.wrap(SOURCE_PROPERTIES_TABLE.fetch(source, {}).fetch(property, property))
    end

    def property_unalias(source, property)
      PROPERTIES_SOURCE_TABLE.fetch(source, {}).fetch(property, property)
    end

    def property_source_priority(property)
      case property
      when :description
        [:html, :oembed, :opengraph_oembed, :opengraph, :default]
      when :image_data, :image_content_type, :image_file_name
        [:image, :oembed, :opengraph_oembed, :opengraph, :default]
      when :page_content_type
        [:headers]
      else
        [:oembed, :opengraph_oembed, :opengraph, :html, :image, :default]
      end
    end

    def add_source_properties!(sources)
      sources.symbolize_keys!
      sources.reject! { |_, properties| properties.empty? }
      sources.select! { |source, _| SOURCES.include?(source) }
      sources.each do |source, properties|
        properties.symbolize_keys!
        properties.reject! { |_, value| value.blank? }
        prioritized_properties(source, properties).each do |property, value|
          next if @sources[source][property]
          @sources[source][property] = normalize_property(property_unalias(source, property), value)
        end
      end
      parser.discovered_uris.each do |uri|
        crawler.enqueue!(uri)
      end
    end

    def extract(property)
      until crawler.finished?
        break if property?(property)
        data = crawler.dequeue!(property_source_priority(property))
        properties = parser.parse(data)
        add_source_properties!(properties)
      end
      get_property(property)
    end

    def extract_all
      PROPERTIES.each do |property|
        send(property)
      end
    end

    def strip_html(value)
      Nokogiri::HTML(value).xpath('//text()').remove.to_s
    end

    def as_oembed_link
      {
        version: '1.0',
        provider_name: site_name,
        provider_url: site_url,
        url: url,
        title: title,
        favicon: favicon,
        description: description,
        type: 'link',
        thumbnail_url: image_url
      }.reject { |_, v| v.nil? }
    end

    def as_oembed_image
      {
        version: '1.0',
        type: 'photo',
        url: image_url,
        name: image_file_name
      }.reject { |_, v| v.nil? }
    end

    def as_oembed_video
      as_oembed_link.merge(type: 'video',
                           html: content_html,
                           width: content_width_scaled.to_i,
                           height: content_height_scaled.to_i)
    end

    def content_type_video?
      content_type =~ %r{\Avideo/.*} ? true : false
    end

    def content_type_iframe?
      content_type =~ %r{\Atext/html} ? true : false
    end

    def content_type_flash?
      content_type == 'application/x-shockwave-flash'
    end

    def content_type_embed?
      get_property(:html) ? true : false
    end

    def content_type_image?
      page_is_image = page_content_type =~ /image/ || page_content_type == 'binary/octet-stream'
      page_is_image_viewer = (image_content_type =~ /image/ || image_content_type == 'binary/octet-stream') && (get_property(:type) == 'image' || get_property(:title) == url)
      page_is_image || page_is_image_viewer
    end

    def content_html
      return content_html_embed if content_type_embed?
      return content_html_iframe if content_type_iframe?
      return content_html_video if content_type_video?
      return content_html_flash if content_type_flash?
    end

    def content_html_embed
      get_property(:html)
    end

    def content_html_video
      return unless content_url.present?
      width_attribute = %(width="#{content_width_scaled}") if content_width_scaled > 0
      height_attribute = %(height="#{content_height_scaled}") if content_height_scaled > 0
      <<-EOF.strip.gsub(/\s+/, ' ').gsub(/>\s+</, '><')
        <video #{width_attribute} #{height_attribute} controls>
          <source src="#{content_url}"
                  type="#{content_type}" />
        </video>
      EOF
    end

    def content_html_iframe
      return unless content_url.present?
      width_attribute = %(width="#{content_width_scaled}") if content_width_scaled > 0
      height_attribute = %(height="#{content_height_scaled}") if content_height_scaled > 0
      <<-EOF.strip.gsub(/\s+/, ' ').gsub(/>\s+</, '><')
        <iframe src="#{content_url}" #{width_attribute} #{height_attribute} allowfullscreen="true" />
      EOF
    end

    def content_html_flash
      return unless content_url.present?
      <<-EOF.strip.gsub(/\s+/, ' ').gsub(/>\s+</, '><')
        <object width="#{content_width_scaled}" height="#{content_height_scaled}">
          <param name="movie" value="#{content_url}"></param>
          <param name="allowScriptAccess" value="always"></param>
          <param name="allowFullScreen" value="true"></param>
          <embed src="#{content_url}"
                 type="#{content_type}"
                 allowscriptaccess="always"
                 allowfullscreen="true"
                 width="#{content_width_scaled}" height="#{content_height_scaled}"></embed>
        </object>
      EOF
    end

    def content_width_scaled
      # Width takes precedence over height
      if @options[:width].to_i > 0
        @options[:width]
      elsif @options[:height].to_i > 0 && content_height.to_i > 0
        # Compute scaled width using the ratio of requested height to actual height, round up to prevent truncation
        (((@options[:height].to_i * 1.0) / (content_height.to_i * 1.0)) * content_width.to_i).ceil
      else
        content_width.to_i
      end
    end

    def content_height_scaled
      # Width takes precedence over height
      if @options[:width].to_i > 0 && content_width.to_i > 0 && content_height.to_i > 0
        # Compute scaled height using the ratio of requested width to actual width, round up to prevent truncation
        (((@options[:width].to_i * 1.0) / (content_width.to_i * 1.0)) * content_height.to_i).ceil
      elsif @options[:height].to_i > 0
        @options[:height]
      elsif @options[:width].to_i > 0
        (@options[:width].to_i * (1.0 / @config.default_content_aspect_ratio)).ceil
      else
        content_height.to_i
      end
    end

    private

    def crawler_class
      @crawler_class ||= @options.fetch(:allow_requests, true) ? LinkPreview::HTTPCrawler : LinkPreview::NullCrawler
    end

    def prioritized_properties(source, properties)
      return properties unless prioritized_properties_for_source(source)
      Hash[properties.sort_by { |key, _| prioritized_properties_for_source(source).find_index(key) || -1 }]
    end

    def prioritized_properties_for_source(source)
      @prioritized_properties_for_source ||= {}
      @prioritized_properties_for_source[source] = SOURCE_PROPERTIES_TABLE[source] ? SOURCE_PROPERTIES_TABLE[source].values.flatten : nil
    end
  end
end
