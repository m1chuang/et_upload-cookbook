#!/usr/bin/env ruby

# Generated by Chef for <%= node['fqdn'] %>
# Local modifications will be overwritten.

gem 'aws-sdk', '~> 1.0'
require 'aws-sdk'
require 'find'
require 'shellwords'
require 'fileutils'
require 'net/http'
require 'net/http/post/multipart'
require 'uri'
require 'json'
require 'zlib'
require 'zip'
require 'date'
require 'yaml'

def conf
  @conf ||= YAML.load_file('/opt/evertrue/config.yml')
end

def get_dna(org_slug, key)
  uri = URI.parse(URI.encode(conf[:api_url] + "/1.0/#{org_slug}/dna/#{key}"))
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true

  req = Net::HTTP::Get.new(uri.request_uri)
  response = http.request(req)

  body = JSON.parse(response.body)
  body['response']['data']
end

def send_to_new_importer(org_slug, path, compression, is_full_import, auto_ingest)
  s3 = AWS::S3.new(
    access_key_id: conf[:aws_access_key_id],
    secret_access_key: conf[:aws_secret_access_key]
  )
  bucket = s3.buckets['onboarding.evertrue.com']
  now = DateTime.now.strftime('%Q')
  s3_filename = "#{now}-#{File.basename(path)}"
  bucket.objects["#{org_slug}/data/#{s3_filename}"].write(Pathname.new(path))

  app_key = conf[:upload_app_key]
  auth = conf[:upload_auth_token]

  oid = get_oid(org_slug, app_key, auth)

  job_id = post_to_new_importer(oid, s3_filename, compression, is_full_import, app_key, auth)

  if auto_ingest == 0
    puts "skipped auto-ingestion for #{org_slug}"
    return
  end

  queue_to_new_importer(oid, job_id, app_key, auth)
end

def get_oid(org_slug, app_key, auth)
  uri = URI.parse(URI.encode(conf[:api_url] + "/auth/organizations/slug/#{org_slug}?auth=#{auth}&auth_provider=evertrueapptoken&app_key=#{app_key}"))
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true

  req = Net::HTTP::Get.new(uri.request_uri)
  response = http.request(req)
  fail "Error sending org_slug: #{org_slug}, Response: #{response.code}, body: #{response.body}" unless response.code.to_i == 200

  body = JSON.parse(response.body)
  body['id']
end

def post_to_new_importer(oid, s3_filename, compression, is_full_import, app_key, auth)
  uri = URI.parse(URI.encode(conf[:api_url] + "/importer/v1/jobs?oid=#{oid}&auth=#{auth}&auth_provider=evertrueapptoken&app_key=#{app_key}"))
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true

  req = Net::HTTP::Post.new(uri.request_uri)
  req['Content-Type'] = 'application/json'
  req.body = {
    's3_filename' => s3_filename,
    'compression' => compression,
    'prune' => is_full_import,
    'notify' => 1
  }.to_json

  response = http.request(req)
  fail "Error sending oid: #{oid}, file: #{s3_filename}. Response: #{response.code}, body: #{response.body}" unless response.code.to_i == 200

  body = JSON.parse(response.body)
  body['id']
end

def queue_to_new_importer(oid, job_id, app_key, auth)
  uri = URI.parse(URI.encode(conf[:api_url] + "/importer/v1/jobs/queue/#{job_id}?oid=#{oid}&auth=#{auth}&auth_provider=evertrueapptoken&app_key=#{app_key}"))
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true

  req = Net::HTTP::Post.new(uri.request_uri)

  response = http.request(req)
  puts "Error queueing oid: #{oid}, job id: #{job_id}. Response: #{response.code}, body: #{response.body}" unless response.code.to_i == 200
end

def compress_if_not_already(path, compression)
  return path if compression != 'NONE'

  Zlib::GzipWriter.open("#{path}.gz", Zlib::BEST_COMPRESSION) do |gz|
    gz.mtime = File.mtime(path)
    gz.orig_name = File.basename(path)
    File.open(path) do |f|
      IO.copy_stream(f, gz)
    end
  end

  FileUtils.rm(path)
  "#{path}.gz"
end

def process(org_slug, path, compression, auto_ingest)
  return unless `lsof #{Shellwords.shellescape path}`.empty?

  is_full_import = !(File.basename(path) =~ /\.full\./i).nil?

  send_to_new_importer(org_slug, path, compression, is_full_import, auto_ingest)

  puts "sent file #{path} for processing"

  compressed_path = compress_if_not_already(path, compression)

  FileUtils.chmod(0700, compressed_path)
  FileUtils.chown('root', 'root', compressed_path)
  FileUtils.mv(compressed_path, '/var/evertrue/uploads')
end

conf['unames'].each do |uname|
  next if uname == 'trial0928'
  org_slug = /(.*?)\d+$/.match(uname)[1]

  begin
    auto_ingest = get_dna(org_slug, 'ET.Importer.IngestionMode')
    if auto_ingest.nil? || auto_ingest != 'AutoIngest'
      auto_ingest = 0
    else
      auto_ingest = 1
    end

    Find.find("/home/#{uname}/uploads") do |path|
      begin
        case path
        when /.*\.csv$/i
          process(org_slug, path, 'NONE', auto_ingest)
        when /.*\.gz$/i
          process(org_slug, path, 'GZIP', auto_ingest)
        when /.*\.zip$/i
          process(org_slug, path, 'ZIP', auto_ingest)
        end
      rescue => e
        puts "Error processing #{path}: #{e}"
      end
    end
  rescue => e
    puts "Error processing #{org_slug}: #{e}"
  end
end
