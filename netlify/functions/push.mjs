import { createClient } from '@supabase/supabase-js';
import webpush from 'web-push';

const json=(data,status=200)=>new Response(JSON.stringify(data),{status,headers:{'content-type':'application/json','cache-control':'no-store'}});
const allowedHost=host=>host==='fcm.googleapis.com'||host==='web.push.apple.com'||host.endsWith('.push.apple.com')||host==='updates.push.services.mozilla.com'||host==='push.services.mozilla.com'||host.endsWith('.notify.windows.com');
const env=()=>({url:process.env.SUPABASE_URL||process.env.VITE_SUPABASE_URL,key:process.env.SUPABASE_SECRET_KEY||process.env.SUPABASE_SERVICE_ROLE_KEY,publicKey:process.env.VAPID_PUBLIC_KEY,privateKey:process.env.VAPID_PRIVATE_KEY,subject:process.env.VAPID_SUBJECT});

export default async function handler(request){
 const config=env();
 if(request.method==='GET')return config.url&&config.key&&config.publicKey&&config.privateKey&&config.subject
  ?json({publicKey:config.publicKey}):json({error:'Push is not configured'},503);
 if(request.method!=='POST')return json({error:'Method not allowed'},405);
 if(!config.url||!config.key||!config.publicKey||!config.privateKey||!config.subject)return json({error:'Push is not configured'},503);
 if(Number(request.headers.get('content-length')||0)>10000)return json({error:'Request too large'},413);
 let token=request.headers.get('authorization')?.replace(/^Bearer\s+/i,'');
 if(!token)return json({error:'Sign in required'},401);
 const admin=createClient(config.url,config.key,{auth:{persistSession:false,autoRefreshToken:false}});
 const {data:{user},error:authError}=await admin.auth.getUser(token);
 if(authError||!user)return json({error:'Invalid session'},401);
 const {data:profile,error:profileError}=await admin.from('profiles').select('id,status').eq('id',user.id).single();
 if(profileError||profile?.status!=='approved')return json({error:'Account not approved'},403);
 const {data:settings,error:settingsError}=await admin.from('app_settings').select('push_enabled').eq('id',1).single();
 if(settingsError||!settings?.push_enabled)return json({error:'Push notifications are paused'},503);
 let body;try{body=await request.json()}catch{return json({error:'Invalid JSON'},400)}
 webpush.setVapidDetails(config.subject,config.publicKey,config.privateKey);
 if(body.action==='subscribe'){
  const sub=body.subscription;
  if(!sub?.endpoint||!sub.keys?.p256dh||!sub.keys?.auth)return json({error:'Invalid subscription'},400);
  let endpoint;try{endpoint=new URL(sub.endpoint)}catch{return json({error:'Invalid endpoint'},400)}
  if(endpoint.protocol!=='https:'||!allowedHost(endpoint.hostname)||sub.endpoint.length>2000||JSON.stringify(sub).length>4000)return json({error:'Push provider unsupported'},400);
  const [owned,count]=await Promise.all([
    admin.from('push_subscriptions').select('endpoint,user_id').eq('endpoint',sub.endpoint).maybeSingle(),
    admin.from('push_subscriptions').select('endpoint',{count:'exact',head:true}).eq('user_id',user.id)
  ]);
  if(owned.error||count.error)return json({error:'Subscription check failed'},500);
  if(owned.data&&owned.data.user_id!==user.id)return json({error:'Subscription belongs to another account'},409);
  if(!owned.data&&count.count>=5)return json({error:'Maximum five devices per account'},429);
  const {error}=await admin.from('push_subscriptions').upsert({endpoint:sub.endpoint,user_id:user.id,subscription:sub},{onConflict:'endpoint'});
  return error?json({error:'Could not save subscription'},500):json({ok:true});
 }
 if(body.action==='dispatch'){
  let id=Number(body.messageId);
  if(!Number.isSafeInteger(id)||id<1)return json({error:'Invalid message'},400);
  const {data:message,error:messageError}=await admin.from('messages').select('id,room_id,author_id,body,created_at').eq('id',id).single();
  if(messageError||!message||message.author_id!==user.id)return json({error:'Message unavailable'},403);
  if(Date.now()-new Date(message.created_at).getTime()>5*60*1000)return json({error:'Message too old'},400);
  const {error:dedupe}=await admin.from('push_dispatches').insert({message_id:id});
  if(dedupe?.code==='23505')return json({ok:true,alreadySent:true});
  if(dedupe)return json({error:'Push dispatch unavailable'},500);
  const [profiles,room,members,subscriptions,sender]=await Promise.all([
   admin.from('profiles').select('id,status,role,username').eq('status','approved'),
   admin.from('rooms').select('id,is_active,is_private,title').eq('id',message.room_id).single(),
   admin.from('room_members').select('user_id,can_read').eq('room_id',message.room_id),
   admin.from('push_subscriptions').select('endpoint,user_id,subscription').limit(100),
   admin.from('profiles').select('name').eq('id',user.id).single()
  ]);
  if([profiles,room,members,subscriptions,sender].some(x=>x.error)||!room.data?.is_active)return json({error:'Could not resolve recipients'},500);
  let grants=new Map(members.data.map(m=>[m.user_id,m.can_read]));
  let allowed=new Set(profiles.data.filter(p=>p.id!==user.id&&(p.role==='admin'||(room.data.is_private?grants.get(p.id)===true:grants.get(p.id)!==false))).map(p=>p.id));
  let targets=subscriptions.data.filter(s=>allowed.has(s.user_id));
  let summary=message.body.startsWith('::sticker:')?'Sent a sticker':message.body.startsWith('/gif ')?'Sent a GIF':message.body.slice(0,120);
  let users=new Map(profiles.data.map(p=>[p.id,p]));
  let sent=0;
  await Promise.allSettled(targets.map(async target=>{
   let username=users.get(target.user_id)?.username;
   let mentioned=username&&new RegExp(`(^|[^\\w])@${username}(?![\\w])`,'i').test(message.body);
   let payload=JSON.stringify({title:mentioned?`RZYN · ${sender.data.name} mentioned you`:`RZYN · ${sender.data.name}`,body:summary,room:room.data.title,url:'/?open=chat'});
   try{await webpush.sendNotification(target.subscription,payload,{TTL:3600,urgency:'normal'});sent++}
   catch(error){if([404,410].includes(error.statusCode))await admin.from('push_subscriptions').delete().eq('endpoint',target.endpoint)}
  }));
  return json({ok:true,sent});
 }
 return json({error:'Unknown action'},400)
}
