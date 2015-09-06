require "docopt"
require "json"
require "pp"
require "psych"

doc = <<DOCOPT
Docky 0.1

Usage:
  docky [options] check [NAME ...]
  docky [options] start NAME ...
  docky [options] stop NAME ...
  docky [options] restart NAME ...
  docky [options] launch NAME ...
  docky [options] relaunch NAME ...

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

def check(name)
  obj = $conf[name]
  if obj.nil?
    puts "#{name} not found in config file"
    return
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
        return
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

def start(name)
  puts `#{$opts['--docker']} start #{name}`
end

def stop(name)
  puts `#{$opts['--docker']} stop #{name}`
end

def restart(name)
  stop(name)
  start(name)
end

def launch(name)
  obj = $conf[name]
  if $info[name]
    puts "#{name} already exists! Did you mean relaunch?"
    return
  end
  str = "#{$opts['--docker']} run --name #{name} -t -i -d"
  if obj["data"]
    str += " --volumes-from #{obj["data"]}"
  end
  if obj["ports"]
    obj["ports"].each { |port| str += " -p #{port}" }
  end
  if obj["env"]
    obj["env"].each { |k,v| str += " -e #{k}=#{v}" }
  end
  if obj["links"]
    obj["links"].each { |link| str += " --link #{link}" }
  end
  str += " #{obj["image"]}"
  puts str
  puts `#{str}`
end

def destroy(name)
  obj = $conf[name]
  if $info[name].nil?
    puts "#{name} does not seem to exist"
    return
  end
  if obj["image"].nil?
    puts "#{name} has no image"
    puts "cowardly refusing to continue"
    return
  end
  if obj["data"] and $info[obj["data"]].nil?
    puts "data container #{obj["data"]} does not seem to exist"
    puts "cowardly refusing to continue"
    return
  end
  stop(name) if $info[name]["State"]["Running"]
  puts `#{$opts['--docker']} rm #{name}`
  $info.delete(name)
end

def relaunch(name)
  if $info[name].nil?
    puts "#{name} does not seem to exist"
    return
  end

  # get all the current ports
  if $conf[name]["ports"]
    $conf[name]["ports"].map! do |port|
      a = port.split(":")
      if a.length == 1
        p = {hostIp: "0.0.0.0", hostPort: "", containerPort: a[0]}
      elsif a.length == 2
        p = {hostIp: "0.0.0.0", hostPort: a[0], containerPort: a[1]}
      elsif a.length == 3
        p = {hostIp: a[0], hostPort: a[1], containerPort: a[2]}
      else
        puts "invalid portspec #{port}"
        return
      end
      p[:containerPort] = p[:containerPort]+"/tcp" unless p[:containerPort].include? "/"
      p2 = $info[name]["NetworkSettings"]["Ports"][p[:containerPort]][0]
      if p[:hostPort].empty? and !p2.nil?
        p[:hostPort] = p2["HostPort"]
      end
      "#{p[:hostIp]}:#{p[:hostPort]}:#{p[:containerPort]}"
    end
  end
  destroy(name)
  launch(name)
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
    $opts['NAME'].each {|name| check(name)}
  elsif $opts['start']
    $opts['NAME'].each {|name| start(name)}
  elsif $opts['stop']
    $opts['NAME'].each {|name| stop(name)}
  elsif $opts['restart']
    $opts['NAME'].each {|name| restart(name)}
  elsif $opts['launch']
    prepare
    $opts['NAME'].each {|name| launch(name)}
  elsif $opts['relaunch']
    prepare
    $opts['NAME'].each {|name| relaunch(name)}
  end
rescue Docopt::Exit => e
  puts e.message
end
