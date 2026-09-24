const CACHE='rzyn-shell-v2';
self.addEventListener('install',e=>{e.waitUntil(caches.open(CACHE).then(c=>c.addAll(['/','/icon.svg','/icon-192.png','/icon-512.png','/manifest.webmanifest','/sounds/soft.wav','/sounds/bubble.wav','/sounds/arcade.wav','/sounds/retro.wav','/sounds/chime.wav','/sounds/laser.wav'])));self.skipWaiting()});
self.addEventListener('activate',e=>{e.waitUntil(caches.keys().then(keys=>Promise.all(keys.filter(k=>k!==CACHE).map(k=>caches.delete(k)))));self.clients.claim()});
self.addEventListener('fetch',e=>{if(e.request.method!=='GET'||new URL(e.request.url).origin!==self.location.origin)return; e.respondWith(fetch(e.request).then(async response=>{if(response.ok){let cache=await caches.open(CACHE);cache.put(e.request,response.clone())}return response}).catch(()=>caches.match(e.request)))});
self.addEventListener('push',event=>{
  let data={title:'RZYN Chat',body:'A new message is waiting.'};
  try{data={...data,...event.data?.json()}}catch{}
  event.waitUntil(self.registration.showNotification(data.title,{
    body:data.body,icon:'/icon-192.png',badge:'/icon-192.png',tag:'rzyn-message-'+Date.now(),
    data:{url:data.url||'/'},silent:false
  }));
});
self.addEventListener('notificationclick',event=>{
  event.notification.close();
  let path=event.notification.data?.url||'/';
  event.waitUntil(self.clients.matchAll({type:'window',includeUncontrolled:true}).then(async clients=>{
    for(let client of clients){if(client.url.startsWith(self.location.origin)){await client.focus();client.postMessage({type:'RZYN_OPEN_CHAT'});return}}
    if(self.clients.openWindow)return self.clients.openWindow(path)
  }));
});
