let client;
export async function initBackend(){
 const c=window.APP_CONFIG;
 if(!c?.supabaseUrl||!c?.supabasePublishableKey)return false;
 if(!/^https:\/\/[a-z0-9-]+\.supabase\.co$/.test(c.supabaseUrl))throw Error('შეამოწმეთ Supabase Project URL config.js-ში.');
 if(c.supabasePublishableKey.startsWith('sb_secret_'))throw Error('გამოიყენეთ მხოლოდ publishable ან anon გასაღები.');
 if(c.supabasePublishableKey.startsWith('eyJ')){try{const claims=JSON.parse(atob(c.supabasePublishableKey.split('.')[1].replace(/-/g,'+').replace(/_/g,'/')));if(claims.role!=='anon')throw Error();}catch{throw Error('config.js-ში დაშვებულია მხოლოდ საჯარო anon გასაღები.');}}
 const {createClient}=await import('https://esm.sh/@supabase/supabase-js@2.49.1');
 client=createClient(c.supabaseUrl,c.supabasePublishableKey,{auth:{storage:window.sessionStorage,persistSession:true,autoRefreshToken:true,detectSessionInUrl:false}});
 return true;
}
async function rpc(route,method,payload){
 const {data,error}=await client.rpc('app_api',{route,method,payload:payload||{}});
 if(error){const message=error.code==='42501'?'წვდომა შეზღუდულია. შედით ხელახლა ან მიმართეთ ადმინისტრატორს.':error.code?.startsWith('23')?'შეამოწმეთ ველები: მნიშვნელობა არასწორია ან უკვე გამოიყენება.':error.message;throw Error(message)}
 return data;
}
async function periodComparisonRpc(payload){ const {data,error}=await client.rpc('period_comparison_api',{payload:payload||{}}); if(error)throw Error(error.code==='42501'?'წვდომა შეზღუდულია.':error.message); return data }
async function complianceRpc(route,method,payload){ const {data,error}=await client.rpc('compliance_api',{route,method,payload:payload||{}}); if(error)throw Error(error.code==='42501'?'წვდომა შეზღუდულია.':error.message); return data }
async function adminMonitoringRpc(route,method,payload){ const {data,error}=await client.rpc('monitoring_admin_api',{route,method,payload:payload||{}}); if(error)throw Error(error.code==='42501'?'წვდომა მხოლოდ Admin-ს აქვს.':error.message); return data }
async function monitoringRpc(route,method,payload){
 const {data,error}=await client.rpc('monitoring_api',{route,method,payload:payload||{}});
 if(error){const message=error.code==='42501'?'წვდომა შეზღუდულია.':error.code?.startsWith('23')?'შეამოწმეთ ველები: მნიშვნელობა არასწორია ან უკვე გამოიყენება.':error.message;throw Error(message)}
 return data;
}
async function edge(body){
 const {data,error}=await client.functions.invoke('manage-users',{body});
 if(error){let message='მომხმარებლის მართვა ვერ შესრულდა. შეამოწმეთ Edge Function-ის კონფიგურაცია.';try{const b=await error.context.json();message=b.error||message}catch{}throw Error(message)}
 if(data?.error)throw Error(data.error);return data;
}
export async function api(url,method='GET',body){
 const parsed=new URL(url,'https://app.invalid'),route=parsed.pathname.replace(/^\/api/,'');
 if(route==='/login'){
  const username=body.username.trim().toLowerCase();
  if(!/^[a-z0-9_.-]{3,64}$/.test(username))throw Error('შეამოწმეთ მომხმარებლის სახელი.');
  const {error}=await client.auth.signInWithPassword({email:username+'@'+window.APP_CONFIG.loginDomain,password:body.password});
  if(error)throw Error(error.status===429?'ბევრი მცდელობა. სცადეთ მოგვიანებით.':'მომხმარებელი ან პაროლი არასწორია.');
  try{return await rpc('/me','GET',{})}catch(e){await client.auth.signOut();throw e}
 }
 if(route==='/logout'){const {error}=await client.auth.signOut({scope:'local'});if(error)throw Error('გასვლა ვერ შესრულდა. სცადეთ ხელახლა.');return {ok:true}}
 const {data:{session},error}=await client.auth.getSession();
 if(error||!session)throw Error('გთხოვთ შეხვიდეთ სისტემაში.');
 if(route==='/period-comparison')return periodComparisonRpc(method==='GET'?Object.fromEntries(parsed.searchParams):body);
 if(route.startsWith('/compliance'))return complianceRpc(route.replace('/compliance',''),method,method==='GET'?Object.fromEntries(parsed.searchParams):body);
 if(route.startsWith('/admin/monitoring'))return adminMonitoringRpc(route.replace('/admin/monitoring',''),method,method==='GET'?Object.fromEntries(parsed.searchParams):body);
 if(route.startsWith('/monitoring')||route.startsWith('/notifications'))return monitoringRpc(route,method,method==='GET'?Object.fromEntries(parsed.searchParams):body);
 if(route==='/password'&&method==='POST')return edge({...body,action:'self-password'});
 if(route==='/users'&&method==='POST')return edge({...body,action:'create'});
 const userPatch=route.match(/^\/users\/([a-f0-9-]{36})$/);
 if(userPatch&&method==='PATCH'){
  const id=userPatch[1];
  if(body.password!==undefined)return edge({action:'password',id,password:body.password});
  if(body.role!==undefined)return edge({action:'role',id,role:body.role});
  if(body.active!==undefined)return edge({action:body.active?'restore':'archive',id});
  if(body.name!==undefined||body.username!==undefined)return edge({action:'update-profile',id,name:body.name,username:body.username});
 }
 return rpc(route,method,method==='GET'?Object.fromEntries(parsed.searchParams):body);
}





