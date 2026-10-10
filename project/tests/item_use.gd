# SPDX-License-Identifier: LGPL-2.1-or-later
# Real primary-button packets; run through tools/test/test-item-use.py.
extends SceneTree
var client: GoannaClient
var messages = ""
var forms = []
var failures = 0
func _initialize():
	create_timer(180).timeout.connect(func(): print("FAIL test timeout"); quit(1))
	call_deferred("run")
func _process(_dt):
	if client:
		client.poll_blocks(1)
		for line in client.take_chat():
			messages += str(line.get("message", "")) + "\n"
			print("CHAT ", line)
		forms.append_array(client.take_shown_formspecs())
	return false
func check(ok, label):
	print("PASS " if ok else "FAIL ", label)
	if not ok: failures += 1
func wait_seconds(seconds):
	await create_timer(seconds).timeout
func pose(pitch = 0):
	client.set_player_pose(Vector3(0,1.13,0),pitch,0)
	client.step_player(0.01,{},pitch,0)
func hold(seconds):
	for i in range(int(seconds / 0.05)):
		client.step_interact(0.05,true,false,false)
		await wait_seconds(0.05)
func release():
	client.step_interact(0.05,false,false,false)
	await wait_seconds(0.3)
func state():
	messages=""
	client.send_chat("/probe")
	await wait_seconds(0.6)
	for line in messages.split("\n"):
		var start=line.find("PROBE STATE ")
		if start>=0:
			return JSON.parse_string(line.substr(start+12))
	return {}
func run():
	client=GoannaClient.new()
	root.add_child(client)
	client.connect_to("127.0.0.1",int(OS.get_environment("GOANNA_TEST_PORT")),"itemtest","")
	var started=Time.get_ticks_msec()
	while Time.get_ticks_msec()-started<120000 and (client.status().get("state")!="ready" or not messages.contains("PROBE READY")):
		await wait_seconds(1)
	if client.status().get("state")!="ready":
		check(false,"client ready");quit(1);return
	await wait_seconds(4)
	pose()
	await wait_seconds(1)
	print("POINTED ",client.step_interact(0.05,false,false,false))
	for index in [1,2,3]:
		client.set_wield_index(index)
		await wait_seconds(0.4)
		messages=""
		await hold(1.2)
		await release()
		var tool=["overseer:document","labour:designator","rooms:planner","dorfcraft_runes:chisel"][index]
		check(messages.contains("PROBE USE "+tool+" 1 node"), tool+" calls on_use on node")
		if index==1: check(messages.contains("First corner"),"designation stores first corner")
		if index==2: check(messages.contains("First corner"),"room planner stores first corner")
		if index==3: check(messages.contains("smoothed"),"chisel validates wall material")
		var s=await state()
		check(s.get("counts",{}).get(tool)==1,tool+" does not repeat while held")
		check(s.get("node")=="mcl_core:stone",tool+" does not dig target")
		if index==2:
			forms=[]
			await hold(0.1)
			await release()
			await wait_seconds(0.5)
			print("FORMS ",forms)
			check(str(forms).contains("rooms:new"),"second room corner opens room form")
	client.set_wield_index(4)
	await wait_seconds(0.4)
	await hold(0.1)
	client.set_wield_index(3)
	await hold(0.8)
	var switched=await state()
	check(switched.get("node")=="mcl_core:stone","switching to usable item cancels digging")
	check(switched.get("counts",{}).get("dorfcraft_runes:chisel")==1,"switching during hold does not use item")
	await release()
	await hold(0.1)
	await release()
	switched=await state()
	check(switched.get("counts",{}).get("dorfcraft_runes:chisel")==2,"fresh press after switching uses item")
	client.set_wield_index(0)
	pose(70)
	await wait_seconds(0.5)
	check(client.step_interact(0.05,false,false,false).get("type")=="nothing","document points at air")
	await hold(0.2)
	await release()
	var opened=await state()
	check(opened.get("overseer",false),"document primary click opens overseer")
	check(opened.get("counts",{}).get("overseer:document")==1,"document callback runs once")
	client.send_chat("/overseer")
	await wait_seconds(0.6)
	var closed=await state()
	check(not closed.get("overseer",true) and closed.get("interact",false),"leaving overseer restores interaction")
	pose()
	client.set_wield_index(4)
	await wait_seconds(0.5)
	await hold(4.0)
	await release()
	var dug=await state()
	check(dug.get("node")=="air","ordinary pick still digs stone")
	print("Item use: ",failures," failures")
	client.disconnect_from_server()
	quit(1 if failures else 0)
