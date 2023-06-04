require "json"
require "io"
require "socket"
require "socket/tcp_socket"


alias BinaryEvent = Tuple(Symbol,String,String,IO)
alias JsonEvent = Tuple(Symbol,JSON::Any)
alias JsonMessageHandler = (JSON::Any->)
alias BinaryMessageHandler = (IO->)

class Actor
@client : Client
@name : String

def initialize(@client, @name)
end

def send(command, **kw)
@client.write({
"type"=>command,
"to"=>@name})
end

  macro method_missing(call)
send {{call.name.camelcase(lower: true).stringify}}
  end

end


class Client
@proxy : Proxy?
@sock : TCPSocket
@binary_handlers = Hash(String,Hash(String,Array(BinaryMessageHandler))).new
@json_handlers = Hash(String,Hash(String,Array(JsonMessageHandler))).new
@event_channel = Channel(BinaryEvent|JsonEvent).new

getter! :proxy

def initialize(@sock)
@proxy=Proxy.new(self)
end

def read
sock=@sock
io=IO::Memory.new
while 1
io.clear
while t=sock.read_char
break if t==':'
io << t
end
puts io.tell
io.seek 0
parts=io.gets_to_end.split(":")
puts parts
bulk=false
if parts[0]=="bulk"
bulk=true
actor,type,length=parts[1..3]
length=length.to_u64
else
length=parts[0].to_i
end
io.clear
total=length
while total>0
total -= IO.copy sock, io, total
end
io.seek 0
if bulk
@event_channel.send BinaryEvent.new(:bulk, actor.not_nil!, type.not_nil!, io)
# swap out the blob of io we just sent for a new io
io=IO::Memory.new
else
@event_channel.send JsonEvent.new(:json,JSON.parse(io))
end #non-bulk
end #while 1
end #def

def write(obj)
tmp=obj.to_json
@sock << "#{tmp.size}:#{tmp}"
@sock.flush
end

def no_json(actor, key, &block : JsonMessageHandler)
_no(@json_handlers, actor,key,block)
end

def no_binary(actor, key, &block : JsonMessageHandler)
_no(@binary_handlers, actor,key,block)
end

def _no(h, actor,key,block)
handlers=h.dig? actor, key
if handlers
handlers.delete block
end
end

def on_binary(actor, type, &block : BinaryMessageHandler)
_on_binary(@binary_handlers, actor,type,block)
end

def on_json(actor, key, &block : JsonMessageHandler)
_on_json(@json_handlers, actor,key,block)
end

{% for message_type in %w(binary json) %}
def _on_{{message_type.id}}(h, actor, key, block)
if ! h.has_key?(actor)
h[actor]=Hash(String, Array({{message_type.capitalize.id}}MessageHandler)).new
end
if ! h[actor].has_key?(key)
h[actor][key]=[] of {{message_type.capitalize.id}}MessageHandler
end
h[actor][key] << block
end
{% end %}

def process
while t=@event_channel.receive
bulk = t[0] == :bulk ? true : false
if bulk
t=t.as(BinaryEvent)
actor=t[1]
key=t[2]
puts "#{actor} #{key}"
data=t[3]
h=@binary_handlers
else
t=t.as(JsonEvent)
data=t[1]
actor=data.as_h["from"].as_s
h=@json_handlers
end
# skip this msg if we aren't listening for this actor
if ! h.has_key?(actor)
puts "no watchers for actor #{actor} message #{data}"
next
elsif bulk && h[actor].has_key?(key)
h[actor][key].each do | handler|
handler.as(BinaryMessageHandler).call data.as(IO)
end #each handler
elsif bulk
puts "no bulk handlers for #{actor} #{key} #{data}"
next
elsif ! bulk
data=data.as(JSON::Any)
watching_keys=h[actor].keys
# what keys are we looking for that are in this msg?
keys=watching_keys.select {|key| data[key]? }
if keys.size==0
puts "no watchers for message #{data}"
next
elsif keys.size>1
puts "got msg #{data} but multiple possible keys #{keys} can match this msg"
next
elsif keys.size==1
h[actor][keys[0]].each do | handler|
handler.as(JsonMessageHandler).call data.as(JSON::Any)
end #each handler
end # if handlers
end # if json or binary
end #while
end #def

end


class Proxy
@client : Client

def initialize(@client)
end

  macro method_missing(call)
Actor.new @client, {{call.name.stringify}}
  end

end


class Gui
@client : Client
@root : Actor

def initialize(@client)
@root=client.proxy.root
end

def run
@client.on_json "root", "tabs" do |tabs|
set_selected tabs["tabs"].as_a.find {|t| t["selected"]==true }.not_nil!
end
@client.proxy.root.list_tabs
end

def set_selected(tab)
puts "selected tab #{tab}"
t=Actor.new @client, tab["actor"].as_s
t.get_target
end

end


def main
sock=TCPSocket.new "localhost", 6000
c=Client.new sock
spawn do
c.read
end
sleep 0
g=Gui.new(c)
spawn do
g.run
end
sleep 0
c.process
end


main

