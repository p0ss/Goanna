extends SceneTree
var main
var view
var checks=[]
var measurements=[]
func _initialize():run.call_deferred()
func check(v:bool,s:String)->bool:
 if not v:
  printerr('FAIL ',s);quit(1);return false
 checks.append(s);print('CHECK ',s);return true
func skeletons(node:Node,out:Array):
 if node is Skeleton3D and node.find_bone('head')>=0:
  for c in node.get_children():
   if c is MeshInstance3D:
    out.append({'node':node,'shadow':c.cast_shadow})
 for c in node.get_children():skeletons(c,out)
func measure(mode:String)->Dictionary:
 var all=[];skeletons(main,all)
 var data={'mode':mode,'bodies':[]}
 for e in all:
  if e.shadow==GeometryInstance3D.SHADOW_CASTING_SETTING_OFF or e.shadow==GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY:
   var sk=e.node
   data.bodies.append({'shadow':e.shadow,'head':sk.get_bone_pose_scale(sk.find_bone('head')).x,'jaw':sk.get_bone_pose_scale(sk.find_bone('jaw')).x if sk.find_bone('jaw')>=0 else -1.0})
 measurements.append(data);print('MEASURE ',JSON.stringify(data));return data
func run():
 OS.set_environment('GOANNA_NO_POINTER_CAPTURE','1');OS.set_environment('GOANNA_NO_PBR','1');OS.set_environment('GOANNA_NO_STORE','1')
 view=SubViewport.new();view.size=Vector2i(1600,900);root.add_child(view)
 main=load('res://game/main.tscn').instantiate();main.connection_options={'host':'127.0.0.1','port':31795,'name':'player','password':''};view.add_child(main)
 var deadline=Time.get_ticks_msec()+180000
 while Time.get_ticks_msec()<deadline and main.client.status().get('state')!='ready':await create_timer(.2).timeout
 if not check(main.client.status().get('state')=='ready','Real native server joined'):return
 await create_timer(3).timeout
 main.client.send_chat('/camera_test_body tiger_person')
 await create_timer(5).timeout
 main._set_camera_mode(main.CAMERA_FIRST);await create_timer(.5).timeout
 var first=measure('first')
 var shrunk=false;var shadow=false
 for b in first.bodies:
  if b.shadow==GeometryInstance3D.SHADOW_CASTING_SETTING_OFF and abs(b.head-.01)<.002 and abs(b.jaw-.01)<.002:shrunk=true
  if b.shadow==GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY and abs(b.head-1.0)<.01:shadow=true
 if not check(shrunk,'Tiger head and jaw collapse in first person'):return
 if not check(shadow,'Tiger shadow retains full head'):return
 main._set_camera_mode(main.CAMERA_BEHIND);await create_timer(.5).timeout
 var third=measure('third');var whole=false
 for b in third.bodies:
  if b.shadow==GeometryInstance3D.SHADOW_CASTING_SETTING_OFF and abs(b.head-1.0)<.01 and abs(b.jaw-1.0)<.01:whole=true
 if not check(whole,'Tiger head and jaw return in third person'):return
 main._set_camera_mode(main.CAMERA_FIRST);await create_timer(.5).timeout
 var again=measure('first_again');shrunk=false
 for b in again.bodies:
  if b.shadow==GeometryInstance3D.SHADOW_CASTING_SETTING_OFF and abs(b.head-.01)<.002:shrunk=true
 if not check(shrunk,'Tiger head hides again after camera cycle'):return
 var f=FileAccess.open('/tmp/tiger-camera-result.json',FileAccess.WRITE);f.store_string(JSON.stringify({'checks':checks,'measurements':measurements},'  '));f.close()
 main.client.disconnect_from_server();main.queue_free();await process_frame;view.queue_free();await process_frame;quit()
