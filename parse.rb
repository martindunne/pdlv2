#!/usr/bin/env ruby

require 'rdf'
require 'rdf/ntriples'
require 'linkeddata'
require 'fileutils'

DEFAULT_LICENSE = 'http://usefulinc.com/doap/licenses/gpl'

@objRegex = /#X obj \d+ \d+ /
@msgRegex = /#X msg \d+ \d+ /
@controlInRegex = /#{@objRegex}r(?:eceive){0,1}\s*\\\$0-lv2-(.*);\s*/
@controlOutRegex = /#{@objRegex}s(?:end){0,1}\s*\\\$0-lv2-(.*);\s*/
@controlLabelRegex = /label:\s*(\w*)/
@floatRegex = /\d+(?:\.\d+)?/
@rangeRegex = /range:\s+(#{@floatRegex})\s*(#{@floatRegex})\s*(#{@floatRegex})/

def get_control_data(content)
  data = {}
  data[:symbol] = content.match(/\A(\w+)/)[0]
  data[:label] =
    if content =~ @controlLabelRegex
      $1
    end
  data[:range] = 
    if content =~ @rangeRegex
      [$1.to_f, $2.to_f, $3.to_f]
    end
  return data
end

def parse_pd_file(patch_path)
  input = 0
  output = 0
  name = nil
  uri = nil
  in_controls = []
  out_controls = []
  license = DEFAULT_LICENSE

  File.open(patch_path) do |f|
    lines = []
    #unwrap wrapped lines
    f.readlines.each do |l|
      #pd lines start with # unless they're a continuation
      unless l =~ /\A#/ or lines.size == 0
        l = lines.pop + l
      end
      lines << l.chomp
    end

    lines.each do |l|
      if l =~ /#{@objRegex}dac~\s(.*);\s*/
        $1.scan(/\d+/).each do |d|
          output = d.to_i if d.to_i > output
        end
      elsif l =~ /#{@objRegex}adc~\s(.*);\s*/
        $1.scan(/\d+/).each do |d|
          input = d.to_i if d.to_i > input
        end
      elsif l =~ @controlInRegex
        in_controls << get_control_data($1)
      elsif l =~ @controlOutRegex
        out_controls << get_control_data($1)
      elsif l =~ /#{@msgRegex}pluginURI:\s(.*);\s*/
        uri = $1
      elsif l =~ /#{@msgRegex}pluginName:\s(.*);\s*/
        name = $1
      elsif l =~ /#{@msgRegex}pluginLicense:\s(.*);\s*/
        license = $1
      end
    end

    raise "need uri" unless uri
    raise "need name" unless name
    raise "need at least one control or audio input or output" unless input + output + in_controls.size + out_controls.size > 0

    outdata = {
      :name => name,
      :uri => uri,
      :license => license
    }

    outdata[:audio_in] = input
    outdata[:audio_out] = output
    outdata[:control_in] = in_controls if in_controls.size
    outdata[:control_out] = out_controls if out_controls.size
    return outdata
  end
end

def print_control(data)
  r = data[:range]
  puts "\t#{data[:symbol]}"
  puts "\t\tlabel: #{data[:label]}" if data[:label]
  puts "\t\trange: #{r.join(', ')}" if r
end

#audio in, out, control in, out
def ports(data)
  p = []
  data[:audio_in].times do |i|
    d = {:type => :audio, :dir => :in, :symbol => "audio_in_" + i.to_s, :label => "Audio Input #{i}"}
  end
  data[:audio_out].times do |i|
    p << {:type => :audio, :dir => :out, :symbol => "audio_out_" + i.to_s, :label => "Audio Output #{i}"}
  end
  data[:control_in].each do |c|
    p << c.merge({:type => :control, :dir => :in})
  end
  data[:control_out].each do |c|
    p << c.merge({:type => :control, :dir => :out})
  end

  return p
end

def print_plugin(data)
  puts "name: #{data[:name]}"
  puts "uri: #{data[:uri]}"
  puts "license: #{data[:license]}"
  puts "audio inputs: #{data[:audio_in]}"
  puts "audio outputs: #{data[:audio_out]}"

  if data[:control_in].size
    puts "control inputs:"
    data[:control_in].each do |c|
      print_control(c)
    end
  end

  if data[:control_out].size
    puts "control outputs:"
    data[:control_out].each do |c|
      print_control(c)
    end
  end
end

@lv2 = RDF::Vocabulary.new("http://lv2plug.in/ns/lv2core#")
@doap = RDF::Vocabulary.new("http://usefulinc.com/ns/doap#")

def write_rdf(data, path)
  details_file = "details.ttl"
  manifest_file = "manifest.ttl"

  uri = RDF::URI.new(data[:uri])

  manifest = RDF::Graph.new
  manifest << [uri, RDF.type, @lv2.Plugin]
  manifest << [uri, RDF::RDFS.seeAlso, RDF::URI.new(details_file)]

  details = RDF::Graph.new
  details << [uri, RDF.type, @lv2.Plugin]
  details << [uri, @lv2.binary, RDF::URI.new(data[:binary])]
  details << [uri, @doap.name, data[:name]]
  details << [uri, @doap.license, RDF::URI.new(data[:license])]

  ports(data).each_with_index do |p, i|
    node = RDF::Node.new
    details << [uri, @lv2.port, node]
    details << [node, @lv2.index, i]
    details << [node, RDF.type, @lv2.AudioPort] if p[:type] == :audio 
    details << [node, RDF.type, @lv2.ControlPort] if p[:type] == :control 
    details << [node, RDF.type, @lv2.InputPort] if p[:dir] == :in
    details << [node, RDF.type, @lv2.OutputPort] if p[:dir] == :out

    details << [node, @lv2.symbol, p[:symbol]]
    details << [node, @lv2.name, p[:label]]

    if p[:range]
      details << [node, @lv2.minimum, p[:range][0]]
      details << [node, @lv2.maximum, p[:range][2]]
      details << [node, @lv2.default, p[:range][1]]
    end
  end

  FileUtils.mkdir_p(path)
  File.open(File.join(path, manifest_file), "w") do |f|
    f.print manifest.to_ttl
  end
  File.open(File.join(path, details_file), "w") do |f|
    f.print details.to_ttl
  end
end

def write_header(data, path)
  file_path = File.join(path, "plugin.h")
  File.open(file_path, "w") do |f|
    f.puts '#include "defines.h"'
    f.puts "\n"
    f.puts 'namespace pdlv2 {'
    f.puts "  const char * plugin_uri = \"#{data[:uri]}\";"

    f.puts '  const std::vector<pdlv2::PortInfo> ports = {';
    ports(data).each do |p|
      line = '{'
      if p[:type] == :audio
        line = line + (p[:dir] == :out ? "AUDIO_OUT" : "AUDIO_IN")
      elsif p[:type] == :control
        line = line + (p[:dir] == :out ? "CONTROL_OUT" : "CONTROL_IN")
      else
        raise "#{p[:type]} not supported"
      end
      line = line + ", \"#{p[:symbol]}\"},"
      f.puts '    ' + line
    end
    f.puts '  };'
    f.puts '}'
  end
end

plugins = ["plugins/template/plugin.pd"]
plugins.each do |p|
  data = parse_pd_file(p)
  data[:binary] = "pdlv2.so"
  path = File.join("build", data[:name].downcase.gsub(/\s+/, "_") + ".lv2")
  write_rdf(data, path)
  write_header(data, path)
end
