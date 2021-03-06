# Pixelpulse controller
# (C) 2011 Nonolith Labs
# Author: Kevin Mehall <km@kevinmehall.net>
# Distributed under the terms of the GNU GPLv3

pixelpulse = (window.pixelpulse ?= {})

pixelpulse.captureState = new Event()
pixelpulse.layoutChanged = new Event()
pixelpulse.triggeringChanged = new Event()
		
pixelpulse.channelviews = []

$(document).ready ->
	session.parseFlags()

	if flags.perfstat
		$('#perfstat').show()
		
	if flags.demohint
		$('#info').show()
		
	if not flags.webgl
		window.nowebgl=true

	session
		app: "Pixelpulse"
		model: "com.nonolithlabs.cee"
		updateMessage: "You're missing <a href='http://www.nonolithlabs.com/blog/2012/09-19-software-features'>new features</a>"

		reset: ->
			pixelpulse.triggering = false
			$(document.body).removeClass('triggering')
			pixelpulse.destroyView()

		updateDevsMenu: (l) ->
			$('#switchDev').toggle(l.length>1)

		initDevice:	(dev) ->
			dev.captureStateChanged.listen (s) ->
				pixelpulse.captureState.notify(s)

		deviceChanged: (dev) ->
			pixelpulse.initView(dev)
			pixelpulse.captureState.notify(dev.captureState)

		deviceRemoved: ->
