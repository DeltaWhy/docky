require "docopt"
require "json"
require "pp"
require "psych"

doc = <<DOCOPT
Docky 0.1

Usage:
  docky [options] check [NAME ...]

Options:
  -h, --help                   Show this screen.
  --version                    Show version.
  -f FILE, --config FILE       Path to config file [default: ~/docky.yml]
  --docker DOCKER              Docker command [default: docker]

DOCOPT

def dinspect(name)
  return JSON.load(`#{$opts['--docker']} inspect #{name}`)[0]
end

def dinspects(names)
  objs = JSON.load(`#{$opts['--docker']} inspect #{names.join(' ')}`)
  h = {}
  objs.each do |obj|
    h[obj["Name"].sub("/","")] = obj
  end
  h
end

def prepare
  names = []
  images = []
  $opts["NAME"].each do |name|
    names << name
    if $conf[name]
      obj = $conf[name]
      images << obj["image"] if obj["image"]
      obj["data"] = name+"-data" if obj["data"] == true
      names << obj["data"] if obj["data"]
    end
  end
  $info = dinspects(names.uniq)
  $images = {}
  images.uniq.each do |name|
    $images[name] = dinspect(name)
  end
end

def check
  $opts['NAME'].each do |name|
    obj = $conf[name]
    if obj.nil?
      puts "#{name} not found in config file"
      next
    end

    if obj["enabled"] == false
      puts "#{name} is running, should be stopped" if $info[name]["State"]["Running"]
    else
      puts "#{name} is stopped, should be running" unless $info[name]["State"]["Running"]
    end

    if obj["image"]
      if $images[obj["image"]].nil?
        puts "#{name}: image #{obj["image"]} does not exist"
      elsif $images[obj["image"]]["Id"] != $info[name]["Image"]
        puts "#{name} is not running image #{obj["image"]}"
      end
    end

    if obj["data"]
      if $info[obj["data"]].nil?
        puts "#{name} data container #{obj["data"]} does not exist"
      else
        puts "#{name} does not have volumes from #{obj["data"]}" unless $info[name]["HostConfig"]["VolumesFrom"].include? obj["data"]
      end
    end

    unless obj["ports"].nil? or !$info[name]["State"]["Running"]
      obj["ports"].each do |port|
        a = port.split(":")
        if a.length == 1
          p = {hostIp: "0.0.0.0", hostPort: "", containerPort: a[0]}
        elsif a.length == 2
          p = {hostIp: "0.0.0.0", hostPort: a[0], containerPort: a[1]}
        elsif a.length == 3
          p = {hostIp: a[0], hostPort: a[1], containerPort: a[2]}
        else
          puts "invalid portspec #{port}"
          next
        end
        p[:containerPort] = p[:containerPort]+"/tcp" unless p[:containerPort].include? "/"
        p2 = $info[name]["NetworkSettings"]["Ports"][p[:containerPort]]
        if p2.nil? or p2[0]["HostIp"] != p[:hostIp] or p[:hostPort] != "" && p2[0]["HostPort"] != p[:hostPort]
          puts "#{name} does not have port #{port}"
        end
      end
    end

    unless obj["env"].nil?
      obj["env"].each do |k,v|
        unless $info[name]["Config"]["Env"].include? "#{k}=#{v}"
          puts "#{name} does not have env #{k}=#{v}"
        end
      end
    end

    unless obj["links"].nil?
      obj["links"].each do |link|
        exname, _, inname = link.partition(":")
        exname = "/#{exname}" unless exname.start_with? "/"
        inname = "/#{name}/#{inname}" unless inname.start_with? "/"
        unless $info[name]["HostConfig"]["Links"].include? "#{exname}:#{inname}"
          puts "#{name} does not have link #{link}"
        end
      end
    end
  end
end

begin
  $opts = Docopt::docopt(doc, version: 'Docky 0.1')
  $opts['--config'] = File.expand_path($opts['--config'])
  unless File.exists? $opts['--config']
    puts "#{$opts['--config']}: file not found"
    exit 1
  end
  $conf = Psych.load_file $opts['--config']
  $opts['NAME'] = $conf.keys if $opts['NAME'].empty?

  if $opts['check']
    prepare
    check
  end
rescue Docopt::Exit => e
  puts e.message
end
