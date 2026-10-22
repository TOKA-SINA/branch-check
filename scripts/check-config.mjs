import {readFileSync} from 'node:fs';
import vm from 'node:vm';
const ctx={window:{}};vm.runInNewContext(readFileSync(new URL('../web/config.js',import.meta.url),'utf8'),ctx,{timeout:1000});
const c=ctx.window.APP_CONFIG;
if(!/^https:\/\/[a-z0-9-]+\.supabase\.co$/.test(c?.supabaseUrl)||!c?.supabasePublishableKey||c.supabasePublishableKey.startsWith('sb_secret_'))throw Error('Fill web/config.js with your project URL and PUBLIC publishable/anon key before publishing.');
if(c.supabasePublishableKey.startsWith('eyJ')){const claim=JSON.parse(Buffer.from(c.supabasePublishableKey.split('.')[1],'base64url'));if(claim.role!=='anon')throw Error('Only a PUBLIC anon key is allowed in web/config.js');}
if(!/^[a-z0-9.-]+$/.test(c.loginDomain))throw Error('Set loginDomain.');
console.log('Public configuration is ready.');
