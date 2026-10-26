import {createClient} from 'npm:@supabase/supabase-js@2.49.1';

const allowedOrigin = Deno.env.get('ALLOWED_ORIGIN') || '';
const domain = Deno.env.get('LOGIN_DOMAIN') || 'branch-check.invalid';
const url = Deno.env.get('SUPABASE_URL')!;
const key = Deno.env.get('SUPABASE_ANON_KEY')!;
const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

Deno.serve(async (req: Request) => {
 const headers = {'Content-Type':'application/json; charset=utf-8','Cache-Control':'no-store','Vary':'Origin','Access-Control-Allow-Origin':allowedOrigin,'Access-Control-Allow-Headers':'authorization, apikey, content-type, x-client-info','Access-Control-Allow-Methods':'POST, OPTIONS'};
 const reply=(status:number,data:unknown)=>new Response(JSON.stringify(data),{status,headers});
 if(req.method==='OPTIONS')return new Response(null,{status:204,headers});
 if(!allowedOrigin||req.headers.get('origin')!==allowedOrigin)return reply(403,{error:'მოთხოვნის წყარო დაუშვებელია.'});
 if(req.method!=='POST')return reply(405,{error:'დაუშვებელი მეთოდი.'});
 try{
  const token=req.headers.get('authorization')?.match(/^Bearer (.+)$/i)?.[1];
  if(!token)return reply(401,{error:'გთხოვთ შეხვიდეთ სისტემაში.'});
  const authClient=createClient(url,key,{auth:{persistSession:false,autoRefreshToken:false}});
  const {data:identity,error:authError}=await authClient.auth.getUser(token);
  if(authError||!identity.user)return reply(401,{error:'სესია დასრულდა.'});
  const db=createClient(url,serviceKey,{auth:{persistSession:false,autoRefreshToken:false}});
  const {data:actor,error:profileError}=await db.from('profiles').select('id,username,role,active,deleted_at').eq('id',identity.user.id).single();
  const text=await req.text();
  if(new TextEncoder().encode(text).length>10000)return reply(413,{error:'მოთხოვნა ზედმეტად დიდია.'});
  let b:Record<string,unknown>;try{b=JSON.parse(text)}catch{return reply(400,{error:'არასწორი მოთხოვნა.'})}
  if(!b||typeof b!=='object'||Array.isArray(b))return reply(400,{error:'არასწორი მოთხოვნა.'});
  if(profileError||!actor?.active||actor.deleted_at||actor.role !== 'admin'){
   if(b.action!=='self-password')return reply(403,{error:'წვდომა მხოლოდ ადმინისტრატორისთვისაა.'});
  }

  if(b.action==='self-password'){
   if(typeof b.current_password!=='string'||typeof b.password!=='string'||b.password.length<6||b.password.length>128)return reply(400,{error:'პაროლი უნდა შეიცავდეს 6–128 სიმბოლოს.'});
   const {error:check}=await authClient.auth.signInWithPassword({email:identity.user.email!,password:b.current_password});
   if(check)return reply(400,{error:'მიმდინარე პაროლი არასწორია.'});
   const {error}=await db.auth.admin.updateUserById(identity.user.id,{password:b.password});
   if(error)return reply(400,{error:'პაროლის შეცვლა ვერ მოხერხდა.'});
   await db.from('audit').insert({user_id:identity.user.id,action:'user.password.self',target:identity.user.id});
   return reply(200,{ok:true});
  }
  if(actor.role !== 'admin')return reply(403,{error:'წვდომა მხოლოდ ადმინისტრატორისთვისაა.'});
  if(typeof b.password==='string'&&(b.password.length<6||b.password.length>128)&&b.action!=='update-profile')return reply(400,{error:'პაროლი უნდა შეიცავდეს 6–128 სიმბოლოს.'});

  if(b.action==='create'){
   const username=typeof b.username==='string'?b.username.trim().toLowerCase():'';
   const name=typeof b.name==='string'?b.name.trim():'';
   const role=String(b.role||'');
   if(!/^[a-z0-9_.-]{3,64}$/.test(username)||!name||name.length>200||!['inspector','monitoring'].includes(role))return reply(400,{error:'შეამოწმეთ სახელი, მომხმარებლის სახელი და როლი.'});
   if(typeof b.password!=='string'||b.password.length<6||b.password.length>128)return reply(400,{error:'პაროლი უნდა შეიცავდეს 6–128 სიმბოლოს.'});
   const {data:created,error}=await db.auth.admin.createUser({email:username+'@'+domain,password:b.password,email_confirm:true,user_metadata:{name}});
   if(error||!created.user)return reply(400,{error:'ანგარიშის შექმნა ვერ მოხერხდა. შეამოწმეთ, ხომ არ არსებობს ეს მომხმარებელი.'});
   const {error:finishError}=await db.rpc('app_finish_user',{actor_id:actor.id,target_id:created.user.id,new_role:role});
   if(finishError){await db.auth.admin.deleteUser(created.user.id);return reply(409,{error:'ანგარიშის შექმნა ვერ მოხერხდა.'})}
   await db.from('audit').insert({user_id:actor.id,action:'user.created',target:created.user.id});
   return reply(201,{id:created.user.id});
  }

  if(b.action==='password'){
   if(typeof b.id!=='string'||!/^[0-9a-f-]{36}$/i.test(b.id)||typeof b.password!=='string')return reply(400,{error:'არასწორი მომხმარებელი ან პაროლი.'});
   const {data:target}=await db.from('profiles').select('id').eq('id',b.id).single();
   if(!target)return reply(404,{error:'მომხმარებელი ვერ მოიძებნა.'});
   const {error}=await db.auth.admin.updateUserById(b.id,{password:b.password});
   if(error)return reply(400,{error:'პაროლის შეცვლა ვერ მოხერხდა.'});
   await db.from('audit').insert({user_id:actor.id,action:'user.password',target:b.id});
   return reply(200,{ok:true});
  }

  if(b.action==='role'){
   if(typeof b.id!=='string'||!['inspector','monitoring'].includes(String(b.role)))return reply(400,{error:'არასწორი როლი.'});
   if(b.id===actor.id)return reply(400,{error:'საკუთარი Admin როლის შეცვლა დაუშვებელია.'});
   const {data:target}=await db.from('profiles').select('id,role').eq('id',b.id).single();
   if(!target)return reply(404,{error:'მომხმარებელი ვერ მოიძებნა.'});
   const {error}=await db.from('profiles').update({role:String(b.role)}).eq('id',b.id);
   if(error)return reply(400,{error:'როლის შეცვლა ვერ მოხერხდა.'});
   await db.from('audit').insert({user_id:actor.id,action:'user.role.updated',target:b.id});
   return reply(200,{ok:true});
  }

  if(b.action==='update-profile'){
   if(typeof b.id!=='string')return reply(400,{error:'არასწორი მომხმარებელი.'});
   const {data:target}=await db.from('profiles').select('id,username,role,name,active').eq('id',b.id).single();
   if(!target)return reply(404,{error:'მომხმარებელი ვერ მოიძებნა.'});
   const username=typeof b.username==='string'?b.username.trim().toLowerCase():target.username;
   const name=typeof b.name==='string'?b.name.trim():target.name;
   if(!/^[a-z0-9_.-]{3,64}$/.test(username)||!name||name.length>200)return reply(400,{error:'შეამოწმეთ სახელი და username.'});
   if(target.role==='admin'&&username!==target.username)return reply(400,{error:'Admin username-ის შეცვლა ამ workflow-ით დაუშვებელია.'});
   const oldEmail=target.username+'@'+domain,newEmail=username+'@'+domain;
   const {error:authUpdate}=await db.auth.admin.updateUserById(target.id,{email:newEmail,email_confirm:true,user_metadata:{name}});
   if(authUpdate)return reply(400,{error:'Auth username-ის შეცვლა ვერ მოხერხდა.'});
   const {error:profileUpdate}=await db.from('profiles').update({username,name}).eq('id',target.id);
   if(profileUpdate){await db.auth.admin.updateUserById(target.id,{email:oldEmail,email_confirm:true});return reply(400,{error:'პროფილის შეცვლა ვერ მოხერხდა.'})}
   await db.from('audit').insert({user_id:actor.id,action:'user.profile.updated',target:target.id});
   return reply(200,{ok:true});
  }
  if(b.action==='archive'||b.action==='restore'){
   if(typeof b.id!=='string')return reply(400,{error:'არასწორი მომხმარებელი.'});
   const {data:target}=await db.from('profiles').select('id,role,active').eq('id',b.id).single();
   if(!target)return reply(404,{error:'მომხმარებელი ვერ მოიძებნა.'});
   if(target.id===actor.id)return reply(400,{error:'საკუთარი Admin ანგარიშის გათიშვა დაუშვებელია.'});
   const active=b.action==='restore';
   if(!active&&target.role==='inspector'){
    const {count}=await db.from('profiles').select('id',{count:'exact',head:true}).eq('role','inspector').eq('active',true).is('deleted_at',null);
    if((count||0)<=1){const {data:assigned}=await db.from('branches').select('id').eq('supervisor_user_id',target.id).eq('active',true);if((assigned||[]).length)return reply(409,{error:'ბოლო მოქმედი ვაიზერის გათიშვა შეუძლებელია, რადგან ფილიალები აქვს.'})}
   }
   const {error}=await db.from('profiles').update({active,deleted_at:active?null:new Date().toISOString()}).eq('id',target.id);
   if(error)return reply(400,{error:'ანგარიშის სტატუსი ვერ შეიცვალა.'});
   await db.auth.admin.updateUserById(target.id,{ban_duration:active?'none':'876000h'});
   await db.from('audit').insert({user_id:actor.id,action:active?'user.restored':'user.archived',target:target.id});
   return reply(200,{ok:true});
  }

  if(b.action==='delete'){
   if(typeof b.id!=='string'||b.confirmation!=='დიახ ვაცნობიერებ რომ მსურს წაშლა')return reply(400,{error:'წაშლის დასადასტურებლად ზუსტად შეიყვანეთ მოთხოვნილი ტექსტი.'});
   if(b.id===actor.id)return reply(400,{error:'საკუთარი Admin ანგარიშის წაშლა დაუშვებელია.'});
   const {error}=await db.from('profiles').update({active:false,deleted_at:new Date().toISOString()}).eq('id',b.id);
   if(error)return reply(400,{error:'მომხმარებლის არქივირება ვერ მოხერხდა.'});
   await db.auth.admin.updateUserById(String(b.id),{ban_duration:'876000h'});
   await db.from('audit').insert({user_id:actor.id,action:'user.deleted.tombstone',target:String(b.id)});
   return reply(200,{ok:true});
  }

  return reply(400,{error:'უცნობი მოქმედება.'});
 }catch(error){console.error(error);return reply(500,{error:'მოქმედება ვერ შესრულდა. სცადეთ ხელახლა.'})}
});





