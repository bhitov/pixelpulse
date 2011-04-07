var http = require('http'),  
    io = require('socket.io')
    paperboy = require('paperboy')
    path = require('path')
    net = require('net')
    
WEBROOT = path.dirname(__filename);

server = http.createServer(function(req, res){ 
	paperboy.deliver(WEBROOT, req, res)
});
server.listen(8099);
  
var socket = io.listen(server); 
socket.on('clientMessage', function(msg, client){
	if (msg.action == 'set')
		inputsocket.write(JSON.stringify(msg)+'\n', 'utf8')
})

var inputsocket = false;

var inputserver = net.createServer(function (c) {
  inputsocket = c;
  c.setEncoding('utf8')
  c.on('data', function(d){
  	lines = d.replace('\r', '').split('\n')
  	for (var i=0; i<lines.length; i++){
  		if (!lines[i]) continue;
		var obj = JSON.parse(lines[i]);
		socket.broadcast(obj)
  	}
  })
});
inputserver.listen(8098);

