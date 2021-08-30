#!/usr/bin/env ruby
# frozen_string_literal: false

require "trollop"
require File.expand_path('../../../lib/recordandplayback', __FILE__)

require "nokogiri"
require "base64"
require "builder"
require "combine_pdf"
require "csv"
require "fileutils"
require "loofah"
require File.expand_path('../../../lib/recordandplayback/interval_tree', __FILE__)

include IntervalTree

opts = Trollop.options do
  opt :meeting_id, "Meeting id to archive", type: String
  opt :format, "Playback format name", type: String
end

meeting_id = opts[:meeting_id]

logger = Logger.new("/var/log/bigbluebutton/post_publish.log", 'weekly')
logger.level = Logger::INFO
BigBlueButton.logger = logger

BigBlueButton.logger.info("Started exporting PDF for [#{meeting_id}]")

@published_files = "/var/bigbluebutton/published/presentation/#{meeting_id}"

# Creates scratch directories
Dir.mkdir("#{@published_files}/frames") unless File.exist?("#{@published_files}/frames")
Dir.mkdir("#{@published_files}/presentation") unless File.exist?("#{@published_files}/presentation")

# Setting the SVGZ option to true will write less data on the disk.
SVGZ_COMPRESSION = false

FILE_EXTENSION = SVGZ_COMPRESSION ? "svgz" : "svg"

# Leave it as false for BBB >= 2.3 as it stopped supporting live whiteboard
REMOVE_REDUNDANT_SHAPES = false

WhiteboardElement = Struct.new(:begin, :end, :value, :id)
WhiteboardSlide = Struct.new(:href, :begin, :end, :width, :height)

def base64_encode(path)
  return "" if File.directory?(path)

  data = File.open(path).read
  "data:image/#{File.extname(path).delete('.')};base64,#{Base64.strict_encode64(data)}"
end

def convert_whiteboard_shapes(whiteboard)
  # Find shape elements
  whiteboard.xpath("svg/g/g").each do |annotation|
    # Make all annotations visible
    style = annotation.attr("style")
    style.sub! "visibility:hidden", ""
    annotation.set_attribute("style", style)

    shape = annotation.attribute("shape").to_s
    # Convert polls to data schema
    if shape.include? "poll"
      poll = annotation.element_children.first

      path = "#{@published_files}/#{poll.attribute('href')}"
      poll.remove_attribute("href")

      poll.add_namespace_definition("xlink", "http://www.w3.org/1999/xlink")

      data = base64_encode(path)

      poll.set_attribute("xlink:href", data)
    end

    # Convert XHTML to SVG so that text can be shown
    next unless shape.include? "text"

    # Turn style attributes into a hash
    style_values = Hash[*CSV.parse(style, col_sep: ":", row_sep: ";").flatten]

    text_color = style_values["color"]
    font_size = style_values["font-size"].to_f

    annotation.set_attribute("style", "#{style};fill:currentcolor")

    foreign_object = annotation.xpath("switch/foreignObject")

    # Obtain X and Y coordinates of the text
    x = foreign_object.attr("x").to_s
    y = foreign_object.attr("y").to_s
    text_box_width = foreign_object.attr("width").to_s.to_f

    text = foreign_object.children.children

    builder = Builder::XmlMarkup.new
    builder.text(x: x, y: y, fill: text_color, "xml:space" => "preserve") do
      text.each do |line|
        line = Loofah.fragment(line.to_s).scrub!(:strip).text.unicode_normalize

        if line == "<br/>"
          builder.tspan(x: x, dy: "0.9em") { builder << "<br/>" }
        else
          # Assumes a width to height aspect ratio of 0.52 for Arial
          line_breaks = line.chars.each_slice((text_box_width / (font_size * 0.52)).to_i).map(&:join)

          line_breaks.each do |row|
            safe_message = Loofah.fragment(row).scrub!(:escape)
            builder.tspan(x: x, dy: "0.9em") { builder << safe_message }
          end
        end
      end
    end

    annotation.add_child(builder.target!)

    # Remove the <switch> tag
    annotation.xpath("switch").remove
  end

  # Save new shapes.svg copy
  File.open("#{@published_files}/shapes_modified.svg", "w", 0o600) do |file|
    file.write(whiteboard)
  end
end

def parse_whiteboard_shapes(shape_reader)
  slide_in = 0
  slide_out = 0

  shapes = []
  slides = []

  shape_reader.each do |node|
    next unless node.node_type == Nokogiri::XML::Reader::TYPE_ELEMENT

    node_name = node.name
    node_class = node.attribute("class")

    if node_name == "image" && node_class == "slide"
      slide_in = node.attribute("in").to_f
      slide_out = node.attribute("out").to_f

      # Image paths need to follow the URI Data Scheme (for slides and polls)
      path = "#{@published_files}/#{node.attribute('href')}"

      next if path.include?('deskshare')

      data = base64_encode(path)

      slides << WhiteboardSlide.new(data, slide_in, slide_out, node.attribute("width").to_f, node.attribute("height"))
    end

    next unless node_name == "g" && node_class == "shape"

    shape_timestamp = node.attribute("timestamp").to_f
    shape_undo = node.attribute("undo").to_f

    shape_undo = slide_out if shape_undo.negative?

    shape_enter = [shape_timestamp, slide_in].max
    shape_leave = [[shape_undo, slide_in].max, slide_out].min

    xml = "<g style=\"#{node.attribute('style')}\">#{node.inner_xml}</g>"
    id = node.attribute("shape").split("-").last

    shapes << WhiteboardElement.new(shape_enter, shape_leave, xml, id)
  end

  [shapes, slides]
end

def remove_adjacent(array)
  index = 0

  until array[index + 1].nil?
    array[index] = nil if array[index].id == array[index + 1].id
    index += 1
  end

  array.compact
end

def render_whiteboard(slides, shapes)
  shapes_interval_tree = IntervalTree::Tree.new(shapes)
  frame_number = 0

  merged = CombinePDF.new

  slides.each do |slide|
    draw = shapes_interval_tree.search(slide.end - 0.05, unique: false, sort: false)
    draw = [] if draw.nil?

    draw = remove_adjacent(draw) if REMOVE_REDUNDANT_SHAPES && !draw.empty?

    svg_export(draw, slide.href, slide.width, slide.height, frame_number)

    pdf = system("rsvg-convert -f pdf -o #{@published_files}/frames/frame#{frame_number}.pdf #{@published_files}/frames/frame#{frame_number}.#{FILE_EXTENSION}")

    unless pdf
      warn("An error occurred generating the PDF for slide #{frame_number}")
      exit(false)
    end

    merged << CombinePDF.load("#{@published_files}/frames/frame#{frame_number}.pdf")

    frame_number += 1
  end

  merged.save "#{@published_files}/annotated_slides.pdf"
end

def svg_export(draw, slide_href, width, height, frame_number)
  # Builds SVG frame
  builder = Builder::XmlMarkup.new

  builder.svg(width: width, height: height, viewBox: "0 0 #{width} #{height}",
              "xmlns:xlink" => "http://www.w3.org/1999/xlink", 'xmlns' => 'http://www.w3.org/2000/svg') do
    # Display background image
    builder.image('xlink:href': slide_href, width: width, height: height)

    # Adds annotations
    draw.each do |shape|
      builder << shape.value
    end
  end

  File.open("#{@published_files}/frames/frame#{frame_number}.#{FILE_EXTENSION}", "w", 0o600) do |svg|
    if SVGZ_COMPRESSION
      svgz = Zlib::GzipWriter.new(svg, Zlib::BEST_SPEED)
      svgz.write(builder.target!)
      svgz.close
    else
      svg.write(builder.target!)
    end
  end
end

def unique_slides(slides)
  # Only keep the last state of the slides, maintaining original order
  (0..slides.size - 1).each do |i|
    ((i + 1)..slides.size - 1).each do |j|
      next if slides[i].nil? || slides[j].nil?
      if slides[i].href == slides[j].href
        slides[i] = slides[j]
        slides[j] = nil
      end
    end
  end

  slides.compact! || slides
end

def export_pdf
  # Benchmark
  start = Time.now

  convert_whiteboard_shapes(Nokogiri::XML(File.open("#{@published_files}/shapes.svg")).remove_namespaces!)

  shapes, slides = parse_whiteboard_shapes(Nokogiri::XML::Reader(File.open("#{@published_files}/shapes_modified.svg")))
  slides = unique_slides(slides)

  render_whiteboard(slides, shapes)

  BigBlueButton.logger.info("Finished exporting PDF. Total: #{Time.now - start}")
end

export_pdf

# Delete the contents of the scratch directories
FileUtils.rm_rf(["#{@published_files}/frames", "#{@published_files}/shapes_modified.svg"])

exit(0)
