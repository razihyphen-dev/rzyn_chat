const keys=require('web-push').generateVAPIDKeys();
console.log('VAPID_PUBLIC_KEY='+keys.publicKey);
console.log('VAPID_PRIVATE_KEY='+keys.privateKey);
console.log('Keep the private key in Netlify environment variables, never in GitHub.');
