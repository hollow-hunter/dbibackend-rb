#!/usr/bin/env ruby
# frozen_string_literal: true

require 'bundler/setup'
require 'libusb'
require 'pathname'

BUFFER_SEGMENT_DATA_SIZE = 0x100000

class CommandID < Integer
  EXIT = 0
  LIST_DEPRECATED = 1
  FILE_RANGE = 2
  LIST = 3
end

class CommandType < Integer
  REQUEST = 0
  RESPONSE = 1
  ACK = 2
end

class UsbContext
  def initialize(vid, pid)
    usb = LIBUSB::Context.new
    @dev = usb.devices(idVendor: vid, idProduct: pid).first
    raise "Device #{vid}:#{pid} not found" unless @dev

    cfg = @dev.configurations.first
    @out = cfg.interfaces[0].endpoints.find { |ep| ep.direction == :out }
    @in = cfg.interfaces[0].endpoints.find { |ep| ep.direction == :in }
    raise "Device #{vid}:#{pid} output endpoint not found" unless @out
    raise "Device #{vid}:#{pid} input endpoint not found" unless @in
  end

  def read(data_size, timeout = 0)
    result = ''
    @dev.open_interface(0) do |handle|
      result = handle.bulk_transfer(endpoint: @in, dataIn: data_size, timeout: timeout)
    end
    result
  end

  def write(data, timeout = 0)
    @dev.open_interface(0) do |handle|
      handle.bulk_transfer(endpoint: @out, dataOut: data, timeout: timeout)
    end
  end
end

def process_file_range_command(data_size, context, cache = nil)
  puts 'File range'
  context.write(['DBI0', CommandType::ACK, CommandID::FILE_RANGE, data_size].pack('a4III<'))

  file_range_header = context.read(data_size)
  range_size, range_offset, nsp_name_len = file_range_header.unpack('I<Q<I')
  nsp_name = file_range_header[16..-1].force_encoding('utf-8')
  nsp_name = cache[nsp_name] if cache && !cache.empty?

  puts "Range Size: #{range_size}, Range Offset: #{range_offset}, Name len: #{nsp_name_len}, Name: #{nsp_name}"

  response_bytes = ['DBI0', CommandType::RESPONSE, CommandID::FILE_RANGE, range_size].pack('a4III<')
  context.write(response_bytes)

  ack = context.read(16, 0)
  _, cmd_type, cmd_id, data_size = ack.unpack('a4I3')
  puts "Cmd Type: #{cmd_type}, Command id: #{cmd_id}, Data size: #{data_size}"
  puts 'Ack'

  File.open(nsp_name, 'rb') do |f|
    f.seek(range_offset)
    curr_off = 0x0
    end_off = range_size
    read_size = BUFFER_SEGMENT_DATA_SIZE

    while curr_off < end_off
      read_size = end_off - curr_off if curr_off + read_size >= end_off

      buf = f.read(read_size)
      context.write(buf, 0)
      curr_off += read_size
    end
  end
end

def process_exit_command(context)
  puts 'Exit'
  context.write(['DBI0', CommandType::RESPONSE, CommandID::EXIT, 0].pack('a4III<'))
  exit(0)
end

def process_list_command(context, work_dir_path)
  puts 'Get list'

  cached_titles = {}
  Pathname.new(work_dir_path).find do |path|
    if path.file? && (path.extname.downcase == '.nsp' || path.extname.downcase == '.nsz' || path.extname.downcase == '.xci')
      puts path
      cached_titles[path.basename.to_s] = path.to_s
    end
  end

  nsp_path_list = cached_titles.keys.join("\n")
  nsp_path_list_bytes = nsp_path_list.encode('utf-8')
  nsp_path_list_len = nsp_path_list_bytes.bytesize

  context.write(['DBI0', CommandType::RESPONSE, CommandID::LIST, nsp_path_list_len].pack('a4III<'))

  ack = context.read(16, 0)
  _, cmd_type, cmd_id, data_size = ack.unpack('a4I3')
  puts "Cmd Type: #{cmd_type}, Command id: #{cmd_id}, Data size: #{data_size}"
  puts 'Ack'

  context.write(nsp_path_list_bytes)
  cached_titles
end

def poll_commands(context, work_dir_path)
  puts 'Entering command loop'

  cmd_cache = nil
  loop do
    cmd_header = context.read(16, 0)
    magic, cmd_type, cmd_id, data_size = cmd_header.unpack('a4I3')

    next unless magic == 'DBI0'

    puts "Cmd Type: #{cmd_type}, Command id: #{cmd_id}, Data size: #{data_size}"

    case cmd_id
    when CommandID::EXIT
      process_exit_command(context)
    when CommandID::LIST
      cmd_cache = process_list_command(context, work_dir_path)
    when CommandID::FILE_RANGE
      process_file_range_command(data_size, context, cmd_cache)
    else
      puts "Unknown command id: #{cmd_id}"
      process_exit_command(context)
    end
  end
end

def connect_to_switch
  loop do
    begin
      switch_context = UsbContext.new(0x057E, 0x3000)
    rescue => e
      pp e
      puts 'Waiting for switch'
      sleep(1)
      next
    end
    return switch_context
  end
end

def main
  titles_path = ARGV.shift
  raise ArgumentError, 'Path to titles must be provided' unless titles_path

  raise ArgumentError, 'Specified path must be a directory' unless Pathname.new(titles_path).directory?

  poll_commands(connect_to_switch, titles_path)
end

main if __FILE__ == $PROGRAM_NAME
