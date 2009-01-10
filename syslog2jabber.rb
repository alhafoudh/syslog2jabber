#!/usr/bin/env ruby

require 'rubygems'
require 'xmpp4r'
require 'xmpp4r/roster'
require 'yaml'
require 'pp'
require 'file/tail'
require 'socket'
require 'time'

config = YAML.load_file('config.yml')


Jabber::debug = config[:jabber_debug] ||= false
DEBUG = config[:debug] ||= false

#########

class Jabber::JID

	def to_short_s
		s = []
		s << "#@node@" if @node
		s << @domain
		return s.to_s
	end

end

class Syslog2Jabber

	def initialize(config)
		@mainthread = Thread.current

		@config = config
		@friends_list = config[:friends_list]
		@notifications = []
	end

	def login
		log "Logging to jabber account #{@config[:username]}"
		@jid		= Jabber::JID.new(@config[:username])
		@client = Jabber::Client.new(@jid)
		@client.connect
		@client.auth(@config[:password])
		log "Authentication successfull"

		listen_for_subscription_requests
		listen_for_messages

		log "Sending initial presence"
		send_initial_presence

		start_watchers(@config[:watch])

		log "Starting jabber client thread (stopping main thread)"
		Thread.stop
	end

	def logout
		log "Logging out from jabber account"
		@client.close

		log "Stopping jabber client thread (resuming main thread)"
		@mainthread.wakeup
	end

	private
	
	def log(msg)
		logfile = File.new(@config[:logfile], "a")
		logfile.puts format_log(msg)
		puts(format_log(msg)) if DEBUG
	end

	def format_log(str)
		"#{Time.now}: #{str}"
	end

	def send_initial_presence
		@client.send(Jabber::Presence.new.set_status("Up since #{Time.now.utc}"))
	end

	def listen_for_subscription_requests
		@roster	 = Jabber::Roster::Helper.new(@client)

		@roster.add_subscription_request_callback do |item, pres|
			if @friends_list.include?(pres.from.to_short_s) then
				log "ACCEPTING AUTHORIZATION REQUEST FROM: " + pres.from.to_s
				@roster.accept_subscription(pres.from)
			end
		end
	end

	def listen_for_messages
		@client.add_message_callback do |m|
			if m.type != :error
				if @friends_list.include?(m.from.to_short_s) then
					log "#{m.from.to_s} << #{m.body}"
					case m.body
						when /^last.*/
							n = m.body.split(' ')[1].to_i
							n = (n == 0 ? 1 : n)
							log "Lasting #{n} messages"

							from = @notifications.length - n
							to = @notifications.length - 1
							to_send = @notifications[from..to]

							log "#{from} - #{to} / #{@notifications.length}"

							to_send.each do |notification|
								notify_friends(notification[:file],notification[:record],[m.from])		
							end
						when /^!.*/
							cmd = m.body.match(/! (.*)/)[1]
							msg = Jabber::Message.new(m.from)
							msg.type = :chat;
							msg.body = ""
							msg.body += "Executing `#{cmd}`\n"
							msg.body += `#{cmd}`
							@client.send(msg);
					end
				end
			else
				log [m.type.to_s, m.body].join(": ")
			end
		end
	end


	def start_watchers(watchers)
		watchers.each do |src|
			spawn_watcher_thread(src)
		end
	end

	def spawn_watcher_thread(src)
		log "Starting to watch #{src[:file]}"
		Thread.new do
			File.open(src[:file]) do |log|
				log.extend(File::Tail)
				log.backward(0)
				log.interval = src[:interval]
				log.tail do |line|
					handle_syslog_message(src,line.chomp)
				end
			end
		end
	end

	def handle_syslog_message(src,str)
		rules = src[:rules] ||= []

		rules.each do |rule|
			action = rule.first[1]
			rule  = rule.first[0]

			log "#{str} =~ #{rule} ?"
			rx = Regexp.new(rule)
			if !(str =~ rx).nil? then
				log " ^ #{action}"

				if action == 'include'
					sysrec = parse_syslog_string(str)
					notify_friends(src[:file],sysrec)
					@notifications << { :file => src[:file], :record => sysrec }
				else
					return
				end
			end
		end
	end

	def parse_syslog_string(str)
		ss = str.split
		{
			:date			=> Time.parse(ss[0..2].join(' ')),
			:host			=> ss[3],
			:source		=> ss[4].split(':')[0],
			:message	=> ss[5..ss.length].join(' '),
			:raw			=> str
		}
	end

	def notify_friends(file,sysrec,to=[])
		log "Notifying about '#{sysrec[:raw]}'"

		to = @friends_list if to.empty?

		to.each do |to|
			@client.send(create_notify_message(to,file,sysrec))
		end
	end

	def create_notify_message(to,file,sysrec)
		msg = Jabber::Message.new(to)
		msg.type = :chat;
		msg.body = "";
		msg.body += "From #{file} the #{sysrec[:source]} on #{sysrec[:host]} reports: \n"
		msg.body += sysrec[:message]
		msg
	end

end

#Kernel.fork do
	client = Syslog2Jabber.new(config)

	Kernel.trap('INT') do
		client.logout
		exit
	end

	client.login
#end
