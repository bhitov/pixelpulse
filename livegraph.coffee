# Real-time canvas plotting library
# Distributed under the terms of the BSD License
# (C) 2011 Kevin Mehall (Nonolith Labs) <km@kevinmehall.net>

livegraph = if exports? then exports else (this.livegraph = {})

PADDING = livegraph.PADDING = 10
AXIS_SPACING = livegraph.AXIS_SPACING = 25
			
class livegraph.Axis
	constructor: (@min, @max) ->
		if @max == 'auto'
			@autoScroll = min
			@max = 0
		else
			@autoscroll = false
			
		@visibleMin = @min
		@visibleMax = @max
	
	span: -> @visibleMax - @visibleMin
		
	grid: (countHint = 10) ->
		# Based on code from d3.js
		step = Math.pow(10, Math.floor(Math.log(@span() / countHint) / Math.LN10))
		err = countHint / @span() * step;

		# Filter ticks to get closer to the desired count.
		if err <= .15 then step *= 10
		else if err <= .35 then step *= 5
		else if err <= .75 then step *= 2

		# Round start and stop values to step interval.
		gridMin = Math.ceil(Math.max(@visibleMin, @min) / step) * step;
		gridMax = Math.floor(Math.min(@visibleMax, @max) / step) * step + step * .5; # inclusive

		livegraph.arange(gridMin, gridMax, step)
		
	xtransform: (x, geom) ->
		(x - @visibleMin) * geom.width / @span() + geom.xleft
		
	ytransform: (y, geom) ->
		geom.ybottom - (y - @visibleMin) * geom.height / @span()
		
	invYtransform: (ypx, geom) ->
		(geom.ybottom - ypx)/geom.height * @span() + @visibleMin
		
class DigitalAxis
	min = 0
	max = 1
	
	grid: -> [0, 1]
	
	xtransform: (x, geom) -> if x then geom.xleft else geom.xright
	ytransform: (y, geom) -> if y then geom.ytop else geom.ybottom
	invYtransform: (ypx, geom) -> (geom.ybottom - ypx) > geom.height/2
		
livegraph.digitalAxis = new DigitalAxis()

class livegraph.Series
	constructor: (@xdata, @ydata, @color, @style) ->


window.requestAnimFrame = 
	window.requestAnimationFrame ||
	window.webkitRequestAnimationFrame ||
	window.mozRequestAnimationFrame ||
	window.oRequestAnimationFrame ||
	window.msRequestAnimationFrame ||
	(callback, element) -> window.setTimeout(callback, 1000/60)

# Creates a matrix A  =  sx  0   dx
#                        0   sy  dy
#						 0   0   1
# based off of the geometry (view) and axis settings such that
# A * vector(x, y, 1) in unit space = the point in pixel space
# or, alternatively, x'=x*sx+dx; y'=y*sy+dy
makeTransform = livegraph.makeTransform = (geom, xaxis, yaxis, w, h) ->
	sx = geom.width / xaxis.span()
	sy = -geom.height / yaxis.span()
	dx = geom.xleft - xaxis.visibleMin*sx
	dy = geom.ybottom - yaxis.visibleMin*sy
	return [sx, sy, dx, dy]

# Apply a transformation generated by makeTransform to a point
transform = livegraph.transform = (x, y, [sx, sy, dx, dy]) -> 
	return [dx + x*sx, dy+y*sy]

# Use a transformation from makeTransform to go from pixel to unit space
invTransform = livegraph.invTransform = (x, y, [sx, sy, dx, dy]) ->
	return [(x-dx)/sx, (y-dy)/sy]
	
# Snap a pixel coordinate to a position that will create a sharp line
snapPx = (px) -> Math.round(px - 0.5) + 0.5 
	
relMousePos = (elem, event) ->
	o = $(elem).offset()
	return [event.pageX-o.left, event.pageY-o.top]
		
class livegraph.canvas
	constructor: (@div, @xaxis, @yaxis, @series, opts={}) ->		
		@div.setAttribute('class', 'livegraph')
		
		@axisCanvas = document.createElement('canvas')
		@graphCanvas = document.createElement('canvas')
		@div.appendChild(@axisCanvas)
		@div.appendChild(@graphCanvas)
		
		$(@div).mousedown(@mousedown)
		$(@div).dblclick(@doubleclick)
		
		@showYleft = opts.yleft ? true
		@showYright = opts.yright ? true
		@showYgrid = opts.ygrid ? true
		@showXbottom = opts.xbottom ? false
		@showXgrid = opts.xgrid ? false
		@gridcolor = opts.gridcolor ? 'rgba(0,0,0,0.08)'
		
		@ctxa = @axisCanvas.getContext('2d')
		
		if not @init_webgl() then @init_canvas2d()
		
		@resized()
		
	init_canvas2d: ->
		@ctxg = @graphCanvas.getContext('2d')
		@redrawGraph = @redrawGraph_canvas2d
		@refreshViewParams = -> false
		@renderer = 'canvas2d'
		return true
		
	init_webgl: ->
		shader_vs = """
			attribute float x;
			attribute float y;

			uniform mat4 transform;

			void main(void) {
				gl_Position = transform * vec4(x, y, 1.0, 1.0);
				gl_Position.z = -1.0;
				gl_Position.w = 1.0;
			}
		"""
		
		shader_fs = """
			#ifdef GL_ES
			precision mediump float;
			#endif
			
			uniform vec4 color;

			void main(void) {
				gl_FragColor = color;
			}
		"""
		
		@gl = gl = @graphCanvas.getContext("experimental-webgl")
		if not @gl then return false
		
		compile_shader = (type, source) ->
			s = gl.createShader(type)
			gl.shaderSource(s, source)
			gl.compileShader(s)
			if !gl.getShaderParameter(s, gl.COMPILE_STATUS)
				console.error(gl.getShaderInfoLog(s))
				return null
			return s
			
		fs = compile_shader(gl.FRAGMENT_SHADER, shader_fs)
		vs = compile_shader(gl.VERTEX_SHADER, shader_vs)
		
		if not fs and vs then return false
		
		gl.shaderProgram = gl.createProgram()
		gl.attachShader(gl.shaderProgram, fs)
		gl.attachShader(gl.shaderProgram, vs)
		gl.linkProgram(gl.shaderProgram)
		
		if (!gl.getProgramParameter(gl.shaderProgram, gl.LINK_STATUS))
			console.error "Could not initialize shaders"
			return false
			
		gl.useProgram(gl.shaderProgram)
		gl.shaderProgram.attrib =
			x: gl.getAttribLocation(gl.shaderProgram, "x")
			y: gl.getAttribLocation(gl.shaderProgram, "y")
		gl.shaderProgram.uniform =
			transform: gl.getUniformLocation(gl.shaderProgram, "transform")
			color: gl.getUniformLocation(gl.shaderProgram, "color")
			
		gl.enableVertexAttribArray(gl.shaderProgram.attrib.x)
		gl.enableVertexAttribArray(gl.shaderProgram.attrib.y)
		
		gl.enable(gl.GL_LINE_SMOOTH)
		gl.hint(gl.GL_LINE_SMOOTH_HINT, gl.GL_NICEST)
		gl.enable(gl.GL_BLEND)
		gl.blendFunc(gl.GL_SRC_ALPHA, gl.GL_ONE_MINUS_SRC_ALPHA)
			
		gl.xBuffer = gl.createBuffer()
		gl.yBuffer = gl.createBuffer()

		@renderer = 'webgl'
		@redrawGraph = @redrawGraph_webgl
		@refreshViewParams = @webgl_refreshViewParams
		return true
		
	perfStat_enable: (div)->
		@psDiv = div
		@psCount = 0
		@psSum = 0
		@psRunningSum = 0
		@psRunningCount = 0

		setInterval((=> 
			@psRunningSum += @psSum
			@psRunningCount += @psCount
			@psDiv.innerHTML = "#{@renderer}: #{@psCount}fps; #{@psSum}ms draw time; Avg: #{@psRunningSum/@psRunningCount}"
			@psCount = 0
			@psSum = 0
		), 1000)

	perfStat: (time) ->
		@psCount += 1
		@psSum += time
		
	mousedown: (e) =>
		pos = origPos = relMousePos(@div, e)
		@dragAction = @onClick(pos)
		if not @dragAction then return
		
		mousemove = (e) =>
			pos = relMousePos(@div, e)
			if @dragAction then @dragAction.onDrag(pos, origPos)
			return
			
		mouseup = =>
			if @dragAction then @dragAction.onRelease(pos, origPos)
			$(window).unbind('mousemove', mousemove)
			         .unbind('mouseup', mouseup)
                     .css('cursor', 'auto')
			return
				
		$(window).mousemove(mousemove)
		         .mouseup(mouseup)
		
	onClick: (pos) -> false
		
	doubleclick: (e) =>
		pos = origPos = relMousePos(@div, e)
		@dragAction = @onDblClick(e, pos)
		
	onDblClick: (e, pos) ->
		
	
	resized: () ->
		if @div.offsetWidth == 0 or @div.offsetHeight == 0 then return
		if not (@xaxis and @yaxis) then return
			
		@width = @div.offsetWidth
		@height = @div.offsetHeight
		@axisCanvas.width = @width
		@axisCanvas.height = @height
		@graphCanvas.width = @width
		@graphCanvas.height = @height
		
		@geom = 
			ytop: PADDING
			ybottom: @height - (PADDING + @showXbottom * AXIS_SPACING)
			xleft: PADDING + @showYleft * AXIS_SPACING
			xright: @width - (PADDING + @showYright * AXIS_SPACING)
			width: @width - 2*PADDING - (@showYleft+@showYright) * AXIS_SPACING
			height: @height - 2*PADDING - @showXbottom  * AXIS_SPACING
			
		@xgridticks = Math.min(@width/50, 10)
		@ygridticks = @height/35

		if @onResized
			@onResized()
			
		@refreshViewParams()
		
		@needsRedraw(true)
		
		if @dot
			@dot.lastY = undefined
			@dot.position(@dot.y)
		
	addDot: (x, fill, stroke) ->
		dot = @dot = livegraph.makeDotCanvas(5, 'white', @cssColor())
		lg = this
		
		dot.position = (y) ->
			dot.y = y
			if not lg.geom then return
			
			# Update visibility, if it has changed
			v =  if !isNaN(y) and y? then 'visible' else 'hidden'
			if dot.style.visibility != v then dot.style.visibility=v
			
			# Find pixel position
			[sx, sy, dx, dy] = makeTransform(lg.geom, lg.xaxis, lg.yaxis)
			ty = Math.round(dy+y*sy)
			
			# Bail out if it hasn't changed
			if not dot.lastY==ty then return
			dot.lastY = ty
			
			if y > lg.yaxis.visibleMax
				y = lg.yaxis.visibleMax
				shape = 'up'
			else if y < lg.yaxis.visibleMin
				y = lg.yaxis.visibleMin
				shape = 'down'
			else
				shape = 'circle'
				
			if dot.shape != shape
				dot.shape = shape
				dot.render()
			
			dot.positionRight(PADDING+AXIS_SPACING, ty)
			
		$(dot).appendTo(@div)
		return dot
			
	redrawAxis: ->
		@ctxa.clearRect(0,0,@width, @height)
		
		if @showXgrid	then @drawXgrid()
		if @showXbottom then @drawXAxis(@geom.ybottom)	
		if @showYgrid   then @drawYgrid()	
		if @showYleft   then @drawYAxis(@geom.xleft,  'right', -5)
		if @showYright  then @drawYAxis(@geom.xright, 'left',   8)
		
	drawXAxis: (y) ->
		xgrid = @xaxis.grid(@xgridticks)
		@ctxa.strokeStyle = 'black'
		@ctxa.lineWidth = 1
		@ctxa.beginPath()
		@ctxa.moveTo(snapPx(@geom.xleft), snapPx(y))
		@ctxa.lineTo(snapPx(@geom.xright), snapPx(y))
		@ctxa.stroke()
		
		textoffset = 5
		@ctxa.textAlign = 'center'
		@ctxa.textBaseline = 'top'
			
		digits = Math.max(Math.ceil(-Math.log(Math.abs(xgrid[1]-xgrid[0]))/Math.LN10), 0)
		
		for x in xgrid
			@ctxa.beginPath()
			xp = snapPx(@xaxis.xtransform(x, @geom))
			@ctxa.moveTo(xp,y-4)
			@ctxa.lineTo(xp,y+4)
			@ctxa.stroke()
			@ctxa.fillText(x.toFixed(digits), xp ,y+textoffset)
			
	drawXgrid: ->
		grid = @xaxis.grid(@xgridticks)
		@ctxa.strokeStyle = @gridcolor
		@ctxa.lineWidth = 1
		for x in grid
			xp = snapPx(@xaxis.xtransform(x, @geom))
			@ctxa.beginPath()
			@ctxa.moveTo(xp, @geom.ybottom)
			@ctxa.lineTo(xp, @geom.ytop)
			@ctxa.stroke()
		
	drawYAxis: (x, align, textoffset) =>
		grid = @yaxis.grid(@ygridticks)
		@ctxa.strokeStyle = 'black'
		@ctxa.lineWidth = 1
		@ctxa.textAlign = align
		@ctxa.textBaseline = 'middle'
		
		@ctxa.beginPath()
		@ctxa.moveTo(snapPx(x), snapPx(@geom.ytop))
		@ctxa.lineTo(snapPx(x), snapPx(@geom.ybottom))
		@ctxa.stroke()
		
		for y in grid
			yp = snapPx(@yaxis.ytransform(y, @geom))
			
			#draw side axis ticks and labels
			@ctxa.beginPath()
			@ctxa.moveTo(x-4, yp)
			@ctxa.lineTo(x+4, yp)
			@ctxa.stroke()
			@ctxa.fillText(Math.round(y*10)/10, x+textoffset, yp)
			
	drawYgrid: ->
		grid = @yaxis.grid(@ygridticks)
		@ctxa.strokeStyle = @gridcolor
		@ctxa.lineWidth = 1
		for y in grid
			yp = snapPx(@yaxis.ytransform(y, @geom))
			@ctxa.beginPath()
			@ctxa.moveTo(@geom.xleft, yp)
			@ctxa.lineTo(@geom.xright, yp)
			@ctxa.stroke()
		
	needsRedraw: (fullRedraw=false) ->
		@axisRedrawRequested ||= fullRedraw
		if not @redrawRequested
			@redrawRequested = true
			requestAnimFrame(@redraw, @graphCanvas)

	redraw: =>
		startTime = new Date()
		
		if @height != @div.offsetHeight or @width != @div.offsetWidth
			@resized()
		
		@redrawRequested = false
		
		if @dragAction
			@dragAction.onAnim()
			
		if @axisRedrawRequested
			@redrawAxis()
			@refreshViewParams()
			@axisRedrawRequested = false
			
		@redrawGraph()
		
		@perfStat(new Date()-startTime)
		return
		
	cssColor: -> "rgb(#{@series[0].color[0]},#{@series[0].color[1]},#{@series[0].color[2]})"		
			
	redrawGraph_canvas2d: ->
		@ctxg.clearRect(0,0,@width, @height)
		@ctxg.lineWidth = 2
		
		[sx, sy, dx, dy] = makeTransform(@geom, @xaxis, @yaxis)
		
		for series in @series
			@ctxg.strokeStyle = @cssColor()
			 
			@ctxg.save()
			
			@ctxg.beginPath()
			@ctxg.rect(@geom.xleft, @geom.ytop, @geom.xright-@geom.xleft, @geom.ybottom-@geom.ytop)
			@ctxg.clip()
			
			@ctxg.beginPath()
			datalen = Math.min(series.xdata.length, series.ydata.length)
			
			cull = true
			
			for i in [0...datalen]
				if cull and series.xdata[i+1] < @xaxis.visibleMin
					continue
				
				x = series.xdata[i]
				y = series.ydata[i]
					
				@ctxg.lineTo(x*sx + dx, y*sy+dy)
				
				if cull and x > @xaxis.visibleMax
					break
					
			@ctxg.stroke()
			@ctxg.restore()
		
	webgl_refreshViewParams: ->
		gl = @gl
		
		gl.clearColor(0.0, 0.0, 0.0, 0.0)
		gl.enable(gl.SCISSOR_TEST)
		gl.viewport(0, 0, @width, @height)
		gl.scissor(@geom.xleft, @height-@geom.ybottom, @geom.width, @geom.height)
		gl.lineWidth(2)
		
		[sx, sy, dx, dy] = makeTransform(@geom, @xaxis, @yaxis)
		w = 2.0/@width
		h = -2.0/@height

		# column-major order!
		tmatrix = [sx*w, 0, 0, 0,   0, sy*h, 0, 0,   dx*w, dy*h, 0, 0,   -1, 1, -1, 1]
		
		gl.uniformMatrix4fv(gl.shaderProgram.uniform.transform, false, new Float32Array(tmatrix))
		gl.uniform4fv(gl.shaderProgram.uniform.color, new Float32Array(
			[@series[0].color[0]/255.0, @series[0].color[1]/255.0, @series[0].color[2]/255.0, 1]))
	
	redrawGraph_webgl: ->
		gl = @gl
		
		gl.clear(gl.COLOR_BUFFER_BIT)
		
		for series in @series
			gl.bindBuffer(gl.ARRAY_BUFFER, gl.xBuffer)
			gl.bufferData(gl.ARRAY_BUFFER, series.xdata, gl.STREAM_DRAW)
			gl.vertexAttribPointer(gl.shaderProgram.attrib.x, 1, gl.FLOAT, false, 0, 0)
			gl.bindBuffer(gl.ARRAY_BUFFER, gl.yBuffer)
			gl.bufferData(gl.ARRAY_BUFFER, series.ydata, gl.STREAM_DRAW)
			gl.vertexAttribPointer(gl.shaderProgram.attrib.y, 1, gl.FLOAT, false, 0, 0)
			gl.drawArrays(gl.LINE_STRIP, 0, series.xdata.length)

# Abstract base for classes that manage user interactions with a Livegraph
# lg - The LiveGraph which started the interaction.
#      Its properties will be used by default
# origPos - The original position of the user action
# allTargets - other LiveGraph instances that need to be updated
#              because they share state - e.g. axes
class livegraph.Action
	constructor: (@lg, @origPos, @allTargets=[@lg], @doneCallback) ->
		@stop = false
		
		for tgt in @allTargets
			if tgt.dragAction
				tgt.dragAction.cancel()
				delete tgt.dragAction
	
	# Queue a redraw of all target graphs
	redraw: (redrawAxes) ->
		for graph in @allTargets
			graph.needsRedraw(redrawAxes)
	
	# Prevent further effects
	# (subclasses should test this flag)		
	cancel: ->
		@stop = true
		if @doneCallback then @doneCallback()
		@doneCallback = null
		
	# Called when the mouse is dragged with the button still down
	onDrag: ([x, y]) ->
	
	# Called when the button is released
	onRelease: ->
	
	# Called on the redraw event
	onAnim: ->
	
	
	

# Helper for the drag-to scroll behavior with momentum and rebound	
class livegraph.DragScrollAction extends livegraph.Action	
	constructor: (lg, origPos, allTargets=null, doneCallback=null) ->
		super(lg, origPos, allTargets, doneCallback)
		
		# Save some original state
		@origMin = @lg.xaxis.visibleMin
		@origMax = @lg.xaxis.visibleMax
		@span = @lg.xaxis.span()
		
		# Conversion factor - pixels per graph unit
		@scale = makeTransform(@lg.geom, @lg.xaxis, @lg.yaxis)[0]
		
		@velocity = 0
		@pressed = true
		
		@x = @lastX = @origPos[0]
		@t = +new Date()
	
	onDrag: ([x, y]) ->
		@scrollTo(x)
		@x = x # Save position so onAnim can compute velocity
		
	scrollTo: (x) ->
		scrollby = (x-@origPos[0])/@scale
		@lg.xaxis.visibleMin = @origMin - scrollby
		@lg.xaxis.visibleMax = @origMax - scrollby
		@redraw(true)
		
	onRelease: ->
		@pressed = false
		@t = +new Date()-1
		
		# force a redraw to get animation timer started
		@redraw(true)
		
	onAnim: ->
		if @stop then return
		
		t = +new Date()
		dt = Math.min(t - @t, 100)
		@t = t
		
		if dt == 0 then return
		
		minOvershoot = Math.max(@lg.xaxis.min - @lg.xaxis.visibleMin, 0)
		maxOvershoot = Math.max(@lg.xaxis.visibleMax - @lg.xaxis.max, 0)
		
		if @pressed
			dx = @x - @lastX
			@lastX = @x
			
			@velocity = dx/dt
			overshoot = Math.max(minOvershoot, maxOvershoot)
			if overshoot > 0
				@velocity *= (1-overshoot*@scale)/200
		else
			if minOvershoot*@scale > 1
				if @velocity <= 0
					@velocity = -1*minOvershoot*@scale/100
				else
					@velocity -= 0.1*dt
			else if maxOvershoot*@scale > 1
				if @velocity >= 0
					@velocity = 1*maxOvershoot*@scale/100
				else
					@velocity += 0.1*dt
			else
				vstep = (if @velocity > 0 then 1 else -1) * 0.05
				@velocity -= vstep
				
				if (Math.abs(@velocity)) < Math.abs(vstep)*10
					# Velocity has become negligible
					# But if we're against min/max, stop exactly on it
					if minOvershoot
						@lg.xaxis.visibleMin = @lg.xaxis.min
						@lg.xaxis.visibleMax = @lg.xaxis.min + @span
						@redraw(true)
					else if maxOvershoot
						@lg.xaxis.visibleMin = @lg.xaxis.max - @span
						@lg.xaxis.visibleMax = @lg.xaxis.max 
						@redraw(true)
						
					@cancel()
					return
			
			@x = @x + @velocity*dt
			@scrollTo(@x)

class livegraph.ZoomXAction extends livegraph.Action
	constructor: (opts, lg, origPos, allTargets=null, doneCallback=null) ->
		super(lg, origPos, allTargets, doneCallback)
		
		@time = opts.time
		
		@origMin = @lg.xaxis.visibleMin
		@origMax = @lg.xaxis.visibleMax
		@startSpan = @lg.xaxis.span()
		
		@endSpan = @startSpan * opts.zoomFactor
		@center = invTransform(@origPos[0], @origPos[1], makeTransform(@lg.geom, @lg.xaxis, @lg.yaxis))[0]
		
		@endMin = @center - @endSpan/2
		@endMax = @center + @endSpan/2
		
		tooMax = @endMax > @lg.xaxis.max
		tooMin = @endMin < @lg.xaxis.min
		
		if tooMin and tooMax
			@endMax = @lg.xaxis.max
			@endMin = @lg.xaxis.min
		else if tooMax
			@endMax = @lg.xaxis.max
			@endMin = @endMax - @endSpan
		else if tooMin
			@endMin = @lg.xaxis.min
			@endMax = @endMin + @endSpan
			
		@startT = +new Date()
		@redraw(true)
	
	onAnim: ->
		if @stop then return
		
		t = +new Date() - @startT
		ps = t / @time
		pe = 1-ps
		
		if ps > 1
			@cancel()
		else
			@lg.xaxis.visibleMin = @origMin*pe + @endMin*ps
			@lg.xaxis.visibleMax = @origMax*pe + @endMax*ps
			@redraw(true)
			
	cancel: ->
		# don't want to get stuck between zoom levels
		@lg.xaxis.visibleMin = @endMin
		@lg.xaxis.visibleMax = @endMax
		@redraw(true)
		super()
	
	
livegraph.makeDotCanvas = (radius = 5, fill='white', stroke='blue') ->
	c = document.createElement('canvas')
	c.width = 2*radius + 4
	c.height = 2*radius + 4
	center = radius+2
	c.fill = fill
	c.stroke = stroke
	
	$(c).css
		position: 'absolute'
		'margin-top':-center
		'margin-right':-center
	ctx = c.getContext('2d')

	c.positionLeft = (x, y)->
		c.style.top = "#{y}px"
		c.style.left = "#{x}px"
		c.style.right = "auto"
	c.positionRight = (x, y)->
		c.style.top = "#{y}px"
		c.style.right = "#{x}px"
		c.style.left = "auto"
	
	c.render = ->
		c.width = c.width
		ctx.fillStyle = c.fill
		ctx.strokeStyle = c.stroke
		ctx.lineWidth = 2
		
		switch c.shape
			when 'circle'
				ctx.arc(center, center, radius, 0, Math.PI*2, true);
			when 'down'
				ctx.moveTo(center,             center+radius)
				ctx.lineTo(center+radius*0.86, center-radius*0.5)
				ctx.lineTo(center-radius*0.86, center-radius*0.5)
				ctx.lineTo(center,             center+radius)
			when 'up'
				ctx.moveTo(center,             center-radius)
				ctx.lineTo(center+radius*0.86, center+radius*0.5)
				ctx.lineTo(center-radius*0.86, center+radius*0.5)
				ctx.lineTo(center,             center-radius)
				
		ctx.fill()
		ctx.stroke()
		
	c.render()

	return c
	
	
			
livegraph.arange = (lo, hi, step) ->
	ret = new Float32Array((hi-lo)/step+1)
	for i in [0...ret.length]
		ret[i] = lo + i*step
	return ret
		
livegraph.demo = ->
	xaxis = new livegraph.Axis(-20, 20)
	xaxis.visibleMin = -5
	xaxis.visibleMax = 5
	yaxis = new livegraph.Axis(-1, 3)

	xdata = livegraph.arange(-20, 20, 0.005)
	ydata = new Float32Array(xdata.length)

	updateData = ->
		n = (Math.sin(+new Date()/1000)+2)*0.5

		for i in [0...ydata.length]
			x = xdata[i]
			if x != 0
				ydata[i] = Math.sin(x*Math.PI/n)/x
			else
				ydata[i] = Math.PI/n

	updateData()

	series = new livegraph.Series(xdata, ydata, 'blue')
	lg = new livegraph.canvas(document.getElementById('demoDiv'), xaxis, yaxis, [series])
	lg.needsRedraw()
	
	lg.start = ->
		@iv = setInterval((->
			updateData()
			lg.needsRedraw()
		), 10)
		
	lg.pause = -> 
		clearInterval(@iv)
		

	lg.perfStat_enable(document.getElementById('statDiv'))
	
	lg.start()

	window.lg = lg


