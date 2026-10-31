# SPDX-License-Identifier: LGPL-2.1-or-later
## The overseer's Houses page, for DorfCraft's co-op houses: the fortress's
## houses with their colour and field pattern, the owner's open toggle and
## banish (with the server's confirm step), the offices with a holder
## picker, and the viewer's own workers with labours, a workshop and a
## stream of work. The server sends the page as a "houses" message, on
## request and again on every change; each control sends one
## {"t": "house", "req", "op"} action through the view's pending request,
## so a retry reuses the request id. The server decides everything; this
## only draws its answer. DorfCraft's docs/overseer.md, "Houses".
extends RefCounted

var view: Node
var root: VBoxContainer
var page: Dictionary = {}
# The head asked about, while the server's confirm text is shown.
var confirming := ""
var confirm_text := ""
var swatch_shader: Shader

func _init(owner_ui: RefCounted, parent: Node) -> void:
	# Only the view is kept: holding the controls object back would make a
	# reference cycle that is never freed.
	view = owner_ui.view
	root = VBoxContainer.new()
	root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.add_theme_constant_override("separation", 8)
	parent.add_child(root)
	root.hide()
	render()

func request() -> void:
	view._send({"t": "houses"})

## Takes a "houses" message. Unchanged pages are not rebuilt, so focus stays.
func update(msg: Dictionary) -> void:
	if msg == page: return
	page = msg
	if not confirming.is_empty() and not _house_of_head(confirming).get("can_banish", false):
		confirming = ""
	render()

func _house_of_head(head: String) -> Dictionary:
	for h in _list(page.get("houses")):
		if h is Dictionary and str(h.get("head", "")) == head: return h
	return {}

static func _list(v: Variant) -> Array:
	return (v as Array).slice(0, 256) if v is Array else []

## "<first name> of house <surname>": the server's head_title, else built
## from head_name, else the head's player name.
static func head_label(house: Dictionary) -> String:
	var titled: Variant = house.get("head_title")
	if titled is String and not titled.is_empty(): return titled
	var first: Variant = house.get("head_name")
	var surname := str(house.get("surname", ""))
	if first is String and not first.is_empty() and not surname.is_empty():
		return "%s of house %s" % [first, surname]
	return str(house.get("head", ""))

## Sends one house action, unless another request is still waiting.
func act(fields: Dictionary) -> bool:
	if not view.pending.is_empty():
		view.inspector.text = "Waiting for the server. Retry uses the same request."
		return false
	view.request_id += 1
	var msg := {"t": "house", "req": "camera:%d" % view.request_id}
	msg.merge(fields)
	view.pending = msg
	view._send(msg.duplicate(true))
	view.inspector.text = "Asking the server."
	return true

## The reply to a house action. Banish without confirm answers with the
## server's confirm text, shown with Confirm and Cancel. A refusal redraws
## the page, undoing any toggle the player changed.
func on_reply(sent: Dictionary, msg: Dictionary) -> void:
	if sent.get("op") == "banish" and sent.get("confirm") != true and not msg.get("ok", false):
		var reason := str(msg.get("reason", ""))
		if reason.begins_with("Confirm"):
			confirming = str(sent.get("name", ""))
			confirm_text = reason
	elif sent.get("op") == "banish":
		confirming = ""
	render()

func _swatch(house: Dictionary) -> Control:
	var rect := ColorRect.new()
	rect.custom_minimum_size = Vector2(36, 36)
	rect.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var hex: Variant = house.get("colour")
	var colour := Color.html(hex) if hex is String and Color.html_is_valid(hex) else Color(0.5, 0.5, 0.5)
	if swatch_shader == null:
		swatch_shader = Shader.new()
		swatch_shader.code = view.HOUSE_SWATCH
	var material := ShaderMaterial.new()
	material.shader = swatch_shader
	material.set_shader_parameter("ink", colour)
	material.set_shader_parameter("pattern", view.house_pattern(str(house.get("pattern", ""))))
	rect.material = material
	rect.tooltip_text = "%s, %s" % [str(hex), str(house.get("pattern", "pattern unknown"))]
	return rect

func _heading(text: String) -> void:
	var l: Label = view.ui.label(root, text)
	l.add_theme_font_size_override("font_size", 20)

func render() -> void:
	view._clear_children(root)
	if page.is_empty():
		view.ui.label(root, "Asking the server for the fortress's houses.")
		return
	if page.get("available") != true:
		view.ui.label(root, "Houses are not available on this server.")
		return
	var waiting: bool = not view.pending.is_empty()
	# The owner's controls.
	var open := CheckButton.new()
	open.text = "Open to settlers"
	open.button_pressed = page.get("open") == true
	open.disabled = page.get("can_open") != true or waiting
	open.tooltip_text = "Settlers may join this fortress as a house." if page.get("can_open") == true \
		else "Only the owner opens the fortress to settlers."
	open.toggled.connect(func(on: bool) -> void:
		if not act({"op": "open", "on": on}): render())
	root.add_child(open)
	_heading("Houses")
	var houses := _list(page.get("houses"))
	if houses.is_empty(): view.ui.label(root, "No houses yet.")
	for house in houses:
		if not house is Dictionary: continue
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		root.add_child(row)
		row.add_child(_swatch(house))
		var names: Array[String] = []
		for w in _list(house.get("workers")):
			if w is Dictionary: names.append(str(w.get("name", w.get("id", ""))))
		var text := "%s house%s\nHead: %s\nWorkers: %s" % [str(house.get("surname", "")),
			" (yours)" if house.get("mine") == true else "", head_label(house),
			", ".join(names) if not names.is_empty() else "none"]
		var about: Label = view.ui.label(row, text)
		about.set_meta("house", str(house.get("id", "")))
		if house.get("can_rename") == true:
			_rename(house, waiting)
		if house.get("can_banish") == true:
			var head := str(house.get("head", ""))
			if confirming == head:
				var ask: VBoxContainer = VBoxContainer.new()
				root.add_child(ask)
				view.ui.label(ask, confirm_text)
				var yes: Button = view.ui.button(ask, "Confirm banish", func() -> void:
					act({"op": "banish", "name": head, "confirm": true}))
				yes.disabled = waiting
				view.ui.button(ask, "Keep them", func() -> void:
					confirming = ""
					render())
			else:
				var banish: Button = view.ui.button(root, "Banish %s" % head, func() -> void:
					act({"op": "banish", "name": head}))
				banish.disabled = waiting
				banish.tooltip_text = "Asks first. Their workers stay as fortress workers."
	_offices(waiting)
	_panel(waiting)

# The head's first name and the surname, for the head or the owner.
func _rename(house: Dictionary, waiting: bool) -> void:
	var row := HBoxContainer.new()
	root.add_child(row)
	var fields: Array[LineEdit] = []
	for pair in [["head_name", "First name"], ["surname", "Surname"]]:
		var edit := LineEdit.new()
		edit.placeholder_text = pair[1]
		edit.text = str(house.get(pair[0], ""))
		edit.max_length = 24
		edit.custom_minimum_size = Vector2(96, 44)
		edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		edit.editable = not waiting
		edit.set_meta("rename", pair[0])
		row.add_child(edit)
		fields.append(edit)
	var id := str(house.get("id", ""))
	var go: Button = view.ui.button(row, "Rename", func() -> void:
		var msg := {"op": "rename", "house": id}
		var first := fields[0].text.strip_edges()
		var surname := fields[1].text.strip_edges()
		if not first.is_empty() and first != str(house.get("head_name", "")): msg.first = first
		if not surname.is_empty() and surname != str(house.get("surname", "")): msg.surname = surname
		if msg.size() == 2:
			view.inspector.text = "Change the first name or the surname first."
			return
		act(msg))
	go.size_flags_horizontal = Control.SIZE_SHRINK_END
	go.autowrap_mode = TextServer.AUTOWRAP_OFF
	go.disabled = waiting
	go.set_meta("house", id)

func _offices(waiting: bool) -> void:
	_heading("Offices")
	if page.get("offices_available") != true:
		view.ui.label(root, "Offices are not available on this server.")
		return
	var offices := _list(page.get("offices"))
	if offices.is_empty(): view.ui.label(root, "No offices.")
	for office in offices:
		if not office is Dictionary: continue
		var role := str(office.get("role", ""))
		view.ui.label(root, "%s: %s" % [str(office.get("title", role)).capitalize(), str(office.get("holder_name", "nobody"))])
		if office.get("can_appoint") != true: continue
		var candidates := _list(office.get("candidates"))
		if candidates.is_empty(): candidates = _list(page.get("candidates"))
		var picker := OptionButton.new()
		picker.fit_to_longest_item = false
		picker.custom_minimum_size.y = 44
		picker.set_meta("role", role)
		var ids: Array = []
		for c in candidates:
			if not c is Dictionary or not c.get("id") is String: continue
			picker.add_item(str(c.get("name", c.id)))
			ids.append(c.id)
			if c.id == office.get("holder"): picker.select(picker.item_count - 1)
		if ids.is_empty():
			picker.add_item("No one can take this office")
			picker.disabled = true
		picker.disabled = picker.disabled or waiting
		root.add_child(picker)
		var row := HBoxContainer.new()
		root.add_child(row)
		var appoint: Button = view.ui.button(row, "Appoint", func() -> void:
			if picker.selected >= 0 and picker.selected < ids.size():
				act({"op": "appoint", "role": role, "holder": ids[picker.selected]}))
		appoint.disabled = ids.is_empty() or waiting
		var vacate: Button = view.ui.button(row, "Vacate", func() -> void: act({"op": "appoint", "role": role}))
		vacate.disabled = office.get("holder") == null or waiting

func _panel(waiting: bool) -> void:
	var panel: Variant = page.get("panel")
	if not panel is Dictionary: return
	var workers := _list(panel.get("workers"))
	_heading("Your workers")
	if workers.is_empty():
		view.ui.label(root, "You direct no workers here.")
		return
	var labours := _list(panel.get("labours"))
	var workshops := _list(panel.get("workshops"))
	var streams: Variant = panel.get("streams")
	for w in workers:
		if not w is Dictionary or not w.get("id") is String: continue
		var wid: String = w.id
		var l: Label = view.ui.label(root, str(w.get("name", wid)))
		l.add_theme_font_size_override("font_size", 19)
		var held: Array = _list(w.get("labours"))
		var grid := GridContainer.new()
		grid.columns = 2
		root.add_child(grid)
		for name in labours:
			if not name is String: continue
			var box := CheckBox.new()
			box.text = name.capitalize()
			box.button_pressed = held.has(name)
			box.disabled = waiting
			box.set_meta("labour", name)
			box.set_meta("worker", wid)
			box.toggled.connect(func(on: bool) -> void:
				var next: Array = held.duplicate()
				if on and not next.has(name): next.append(name)
				if not on: next.erase(name)
				next.sort()
				if not act({"op": "labours", "worker": wid, "labours": next}): render())
			grid.add_child(box)
		var shop := OptionButton.new()
		shop.fit_to_longest_item = false
		shop.custom_minimum_size.y = 44
		shop.set_meta("worker", wid)
		shop.add_item("No workshop")
		var ids: Array = [null]
		for ws in workshops:
			if not ws is Dictionary or ws.get("id") == null: continue
			var keeper: Variant = ws.get("worker")
			var title := str(ws.get("title", ws.get("kind", "Workshop")))
			if keeper != null and keeper != wid: title += " (kept)"
			shop.add_item(title)
			ids.append(ws.id)
			if ws.id == w.get("workshop"): shop.select(shop.item_count - 1)
		shop.disabled = waiting
		shop.item_selected.connect(func(i: int) -> void:
			var fields := {"op": "workshop", "worker": wid}
			if ids[i] != null: fields.workshop = ids[i]
			if not act(fields): render())
		root.add_child(shop)
		var stream := OptionButton.new()
		stream.fit_to_longest_item = false
		stream.custom_minimum_size.y = 44
		stream.set_meta("worker", wid)
		if streams is Array and not streams.is_empty():
			for s in streams.slice(0, 64):
				var sid: Variant = s.get("id") if s is Dictionary else s
				stream.add_item(str(s.get("title", sid)) if s is Dictionary else str(s))
				stream.set_item_metadata(stream.item_count - 1, sid)
				if sid == w.get("stream"): stream.select(stream.item_count - 1)
			stream.disabled = waiting
			stream.item_selected.connect(func(i: int) -> void:
				if not act({"op": "stream", "worker": wid, "stream": stream.get_item_metadata(i)}): render())
			root.add_child(stream)
		else:
			# The server offers no streams yet; its reason, when it sends
			# one, says why.
			stream.add_item("Stream of work")
			stream.disabled = true
			stream.tooltip_text = str(panel.get("stream_reason", "Streams of work are not available yet."))
			root.add_child(stream)
			view.ui.label(root, stream.tooltip_text)
