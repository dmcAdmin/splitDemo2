class Wrapper
	constructor: (ws_url) ->
		@log "Created!"

		@loading = new Loading()
		@notifications = new Notifications($(".notifications"))
		@sidebar = new Sidebar()

		window.addEventListener("message", @onMessageInner, false)
		@inner = document.getElementById("inner-iframe").contentWindow
		@ws = new ZeroWebsocket(ws_url)
		@ws.next_message_id = 1000000 # Avoid messageid collision :)
		@ws.onOpen = @onOpenWebsocket
		@ws.onClose = @onCloseWebsocket
		@ws.onMessage = @onMessageWebsocket
		@ws.connect()
		@ws_error = null # Ws error message

		@site_info = null # Hold latest site info
		@event_site_info =  $.Deferred() # Event when site_info received
		@inner_loaded = false # If iframe loaded or not
		@inner_ready = false # Inner frame ready to receive messages
		@wrapperWsInited = false # Wrapper notified on websocket open
		@site_error = null # Latest failed file download
		@address = null

		window.onload = @onLoad # On iframe loaded
		$(window).on "hashchange", => # On hash change
			@log "Hashchange", window.location.hash
			if window.location.hash
				src = $("#inner-iframe").attr("src").replace(/#.*/, "")+window.location.hash
				$("#inner-iframe").attr("src", src)
		@


	# Incoming message from UiServer websocket
	onMessageWebsocket: (e) =>
		message = JSON.parse(e.data)
		cmd = message.cmd
		if cmd == "response"
			if @ws.waiting_cb[message.to]? # We are waiting for response
				@ws.waiting_cb[message.to](message.result)
			else
				@sendInner message # Pass message to inner frame
		else if cmd == "notification" # Display notification
			@notifications.add("notification-#{message.id}", message.params[0], message.params[1], message.params[2])
		else if cmd == "prompt" # Prompt input
			@displayPrompt message.params[0], message.params[1], message.params[2], (res) =>
				@ws.response message.id, res
		else if cmd == "setSiteInfo"
			@sendInner message # Pass to inner frame
			if message.params.address == @address # Current page
				@setSiteInfo message.params
		else if cmd == "updating" # Close connection
			@ws.ws.close()
			@ws.onCloseWebsocket(null, 4000)
		else
			@sendInner message # Pass message to inner frame


	# Incoming message from inner frame
	onMessageInner: (e) =>
		message = e.data
		cmd = message.cmd
		if cmd == "innerReady"
			@inner_ready = true
			if @ws.ws.readyState == 1 and not @wrapperWsInited # If ws already opened
				@sendInner {"cmd": "wrapperOpenedWebsocket"}
				@wrapperWsInited = true
		else if cmd == "wrapperNotification" # Display notification
			@actionNotification(message)
		else if cmd == "wrapperConfirm" # Display confirm message
			@actionConfirm(message)
		else if cmd == "wrapperPrompt" # Prompt input
			@actionPrompt(message)
		else if cmd == "wrapperSetViewport" # Set the viewport
			@actionSetViewport(message)
		else if cmd == "wrapperReload" # Reload current page
			@actionReload(message)
		else if cmd == "wrapperGetLocalStorage"
			@actionGetLocalStorage(message)
		else if cmd == "wrapperSetLocalStorage"
			@actionSetLocalStorage(message)
		else # Send to websocket
			if message.id < 1000000
				@ws.send(message) # Pass message to websocket
			else
				@log "Invalid inner message id"


	# - Actions -

	actionNotification: (message) ->
		message.params = @toHtmlSafe(message.params) # Escape html
		body =  $("<span class='message'>"+message.params[1]+"</span>")
		@notifications.add("notification-#{message.id}", message.params[0], body, message.params[2])



	displayConfirm: (message, caption, cb) ->
		body = $("<span class='message'>"+message+"</span>")
		button = $("<a href='##{caption}' class='button button-#{caption}'>#{caption}</a>") # Add confirm button
		button.on "click", cb
		body.append(button)
		@notifications.add("notification-#{caption}", "ask", body)


	actionConfirm: (message, cb=false) ->
		message.params = @toHtmlSafe(message.params) # Escape html
		if message.params[1] then caption = message.params[1] else caption = "ok"
		@displayConfirm message.params[0], caption, =>
			@sendInner {"cmd": "response", "to": message.id, "result": "boom"} # Response to confirm
			return false



	displayPrompt: (message, type, caption, cb) ->
		body = $("<span class='message'>"+message+"</span>")

		input = $("<input type='#{type}' class='input button-#{type}'/>") # Add input
		input.on "keyup", (e) => # Send on enter
			if e.keyCode == 13
				button.trigger "click" # Response to confirm
		body.append(input)

		button = $("<a href='##{caption}' class='button button-#{caption}'>#{caption}</a>") # Add confirm button
		button.on "click", => # Response on button click
			cb input.val()
			return false
		body.append(button)

		@notifications.add("notification-#{message.id}", "ask", body)


	actionPrompt: (message) ->
		message.params = @toHtmlSafe(message.params) # Escape html
		if message.params[1] then type = message.params[1] else type = "text"
		caption = "OK"
		
		@displayPrompt message.params[0], type, caption, (res) =>
			@sendInner {"cmd": "response", "to": message.id, "result": res} # Response to confirm
		


	actionSetViewport: (message) ->
		@log "actionSetViewport", message
		if $("#viewport").length > 0
			$("#viewport").attr("content", @toHtmlSafe message.params)
		else
			$('<meta name="viewport" id="viewport">').attr("content", @toHtmlSafe message.params).appendTo("head")


	reload: (url_post="") ->
		if url_post
			if window.location.toString().indexOf("?") > 0
				window.location += "&"+url_post
			else
				window.location += "?"+url_post
		else
			window.location.reload()


	actionGetLocalStorage: (message) ->
		$.when(@event_site_info).done => 
			data = localStorage.getItem "site.#{@site_info.address}"
			if data then data = JSON.parse(data)
			@sendInner {"cmd": "response", "to": message.id, "result": data}


	actionSetLocalStorage: (message) ->
		back = localStorage.setItem "site.#{@site_info.address}", JSON.stringify(message.params)


	# EOF actions


	onOpenWebsocket: (e) =>
		@ws.cmd "channelJoin", {"channel": "siteChanged"} # Get info on modifications
		if not @wrapperWsInited and @inner_ready
			@sendInner {"cmd": "wrapperOpenedWebsocket"} # Send to inner frame
			@wrapperWsInited = true
		if @inner_loaded # Update site info
			@reloadSiteInfo()

		# If inner frame not loaded for 2 sec show peer informations on loading screen by loading site info
		setTimeout (=>
			if not @site_info then @reloadSiteInfo()
		), 2000

		if @ws_error 
			@notifications.add("connection", "done", "Connection with <b>UiServer Websocket</b> recovered.", 6000)
			@ws_error = null


	onCloseWebsocket: (e) =>
		@wrapperWsInited = false
		setTimeout (=> # Wait a bit, maybe its page closing
			@sendInner {"cmd": "wrapperClosedWebsocket"} # Send to inner frame
			if e and e.code == 1000 and e.wasClean == false # Server error please reload page
				@ws_error = @notifications.add("connection", "error", "UiServer Websocket error, please reload the page.")
			else if not @ws_error
				@ws_error = @notifications.add("connection", "error", "Connection with <b>UiServer Websocket</b> was lost. Reconnecting...")
		), 1000


	# Iframe loaded
	onLoad: (e) =>
		@inner_loaded = true
		if not @inner_ready then @sendInner {"cmd": "wrapperReady"} # Inner frame loaded before wrapper
		#if not @site_error then @loading.hideScreen() # Hide loading screen
		if window.location.hash then $("#inner-iframe")[0].src += window.location.hash # Hash tag
		if @ws.ws.readyState == 1 and not @site_info # Ws opened
			@reloadSiteInfo()
		else if @site_info and @site_info.content?.title?
			window.document.title = @site_info.content.title+" - ZeroNet"
			@log "Setting title to", window.document.title


	# Send message to innerframe
	sendInner: (message) ->
		@inner.postMessage(message, '*')


	# Get site info from UiServer
	reloadSiteInfo: ->
		if @loading.screen_visible # Loading screen visible
			params = {"file_status": window.file_inner_path} # Query the current required file status
		else
			params = {}
		
		@ws.cmd "siteInfo", params, (site_info) =>
			@address = site_info.address
			@setSiteInfo site_info

			if site_info.settings.size > site_info.size_limit*1024*1024 # Site size too large and not displaying it yet
				@loading.showTooLarge(site_info)

			if site_info.content
				window.document.title = site_info.content.title+" - ZeroNet"
				@log "Setting title to", window.document.title


	# Got setSiteInfo from websocket UiServer
	setSiteInfo: (site_info) ->
		if site_info.event? # If loading screen visible add event to it
			# File started downloading
			if site_info.event[0] == "file_added" and site_info.bad_files
				@loading.printLine("#{site_info.bad_files} files needs to be downloaded")
			# File finished downloading
			else if site_info.event[0] == "file_done"
				@loading.printLine("#{site_info.event[1]} downloaded")
				if site_info.event[1] == window.file_inner_path # File downloaded we currently on
					@loading.hideScreen()
					if not @site_info then @reloadSiteInfo()
					if site_info.content
						window.document.title = site_info.content.title+" - ZeroNet"
						@log "Required file done, setting title to", window.document.title
					if not $(".loadingscreen").length # Loading screen already removed (loaded +2sec)
						@notifications.add("modified", "info", "New version of this page has just released.<br>Reload to see the modified content.")
			# File failed downloading
			else if site_info.event[0] == "file_failed" 
				@site_error = site_info.event[1]
				if site_info.settings.size > site_info.size_limit*1024*1024 # Site size too large and not displaying it yet
					@loading.showTooLarge(site_info)

				else
					@loading.printLine("#{site_info.event[1]} download failed", "error")
			# New peers found
			else if site_info.event[0] == "peers_added" 
				@loading.printLine("Peers found: #{site_info.peers}")

		if @loading.screen_visible and not @site_info # First site info display current peers
			if site_info.peers > 1
				@loading.printLine "Peers found: #{site_info.peers}"
			else
				@site_error = "No peers found"
				@loading.printLine "No peers found"

		if not @site_info and not @loading.screen_visible and $("#inner-iframe").attr("src").indexOf("?") == -1 # First site info and mainpage
			if site_info.size_limit < site_info.next_size_limit # Need upgrade soon
				@wrapperConfirm "Running out of size limit (#{(site_info.settings.size/1024/1024).toFixed(1)}MB/#{site_info.size_limit}MB)", "Set limit to #{site_info.next_size_limit}MB", =>
					@ws.cmd "siteSetLimit", [site_info.next_size_limit], (res) =>
						@notifications.add("size_limit", "done", res, 5000)
					return false

		if @loading.screen_visible and @inner_loaded and site_info.settings.size < site_info.size_limit*1024*1024 # Loading screen still visible, but inner loaded
			@loading.hideScreen()

		if site_info.tasks > 0 and site_info.started_task_num > 0
			@loading.setProgress 1-(site_info.tasks / site_info.started_task_num)
		else
			@loading.hideProgress()

		@site_info = site_info
		@event_site_info.resolve()


	toHtmlSafe: (values) ->
		if values not instanceof Array then values = [values] # Convert to array if its not
		for value, i in values
			value = String(value).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;') # Escape
			value = value.replace(/&lt;([\/]{0,1}(br|b|u|i))&gt;/g, "<$1>") # Unescape b, i, u, br tags
			values[i] = value
		return values


	setSizeLimit: (size_limit, reload=true) =>
		@ws.cmd "siteSetLimit", [size_limit], (res) =>
			@loading.printLine res
			@inner_loaded = false # Inner frame not loaded, just a 404 page displayed
			if reload
				$("iframe").attr "src", $("iframe").attr("src")+"&"+(+new Date) # Reload iframe
		return false



	log: (args...) ->
		console.log "[Wrapper]", args...


if window.server_url
	ws_url = "ws://#{window.server_url.replace('http://', '')}/Websocket?wrapper_key=#{window.wrapper_key}"
else
	ws_url = "ws://#{window.location.hostname}:#{window.location.port}/Websocket?wrapper_key=#{window.wrapper_key}"
window.wrapper = new Wrapper(ws_url)
