import {createClient} from 'npm:@supabase/supabase-js@2.49.1';

const allowedOrigin = Deno.env.get('ALLOWED_ORIGIN') || '';
const domain = Deno.env.get('LOGIN_DOMAIN') || 'branch-check.invalid';
const url = Deno.env.get('SUPABASE_URL')!;
const key = Deno.env.get('SUPABASE_ANON_KEY')!;
const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

Deno.serve(async (req: Request) => {
 const headers = {'Content-Type':'application/json; charset=utf-8','Cache-Control':'no-store','Vary':'Origin','Access-Control-Allow-Origin':allowedOrigin,'Access-Control-Allow-Headers':'authorization, apikey, content-type, x-client-info','Access-Control-Allow-Methods':'POST, OPTIONS'};
 const reply = (status:number,data:unknown) => new Response(JSON.stringify(data),{status,headers});
 if (!allowedOrigin || req.headers.get('origin') !== allowedOrigin) return reply(403,{error:'მოთხოვნის წყარო დაუშვებელია.'});
 if (req.method === 'OPTIONS') return new Response(null,{status:204,headers});
 if (req.method !== 'POST') return reply(405,{error:'დაუშვებელი მეთოდი.'});
 try {
  const token = req.headers.get('authorization')?.match(/^Bearer (.+)$/i)?.[1];
  if (!token) return reply(401,{error:'გთხოვთ შეხვიდეთ სისტემაში.'});
  const authClient = createClient(url,key,{auth:{persistSession:false,autoRefreshToken:false}});
  const {data:identity,error:authError} = await authClient.auth.getUser(token);
  if (authError || !identity.user) return reply(401,{error:'სესია დასრულდა.'});
  const db = createClient(url,serviceKey,{auth:{persistSession:false,autoRefreshToken:false}});
  const {data:actor,error:profileError} = await db.from('profiles').select('id,role,active').eq('id',identity.user.id).single();
  if (profileError || !actor?.active || actor.role !== 'admin') return reply(403,{error:'წვდომა მხოლოდ ადმინისტრატორისთვისაა.'});
  const text = await req.text();
  if (new TextEncoder().encode(text).length > 10000) return reply(413,{error:'მოთხოვნა ზედმეტად დიდია.'});
  let b:Record<string,unknown>;
  try { b = JSON.parse(text); } catch { return reply(400,{error:'არასწორი მოთხოვნა.'}); }
  if (!b || typeof b !== 'object' || Array.isArray(b)) return reply(400,{error:'არასწორი მოთხოვნა.'});
  if (typeof b.password !== 'string' || b.password.length < 6 || b.password.length > 128) return reply(400,{error:'პაროლი უნდა შეიცავდეს 6–128 სიმბოლოს.'});
  if (b.action === 'create') {
   const username = typeof b.username === 'string' ? b.username.trim().toLowerCase() : '';
   const name = typeof b.name === 'string' ? b.name.trim() : '';
   if (!/^[a-z0-9_.-]{3,64}$/.test(username) || !name || name.length > 200 || !['admin','inspector'].includes(String(b.role))) return reply(400,{error:'შეამოწმეთ სახელი, მომხმარებლის სახელი და როლი.'});
   const {data:created,error} = await db.auth.admin.createUser({email:username+'@'+domain,password:b.password,email_confirm:true,user_metadata:{name}});
   if (error || !created.user) return reply(400,{error:'ანგარიშის შექმნა ვერ მოხერხდა. შეამოწმეთ, ხომ არ არსებობს ეს მომხმარებელი.'});
   // The Auth trigger created an INACTIVE inspector. Activation is a separate,
   // server-only operation that rechecks the acting administrator under a lock.
   const {error:finishError} = await db.rpc('app_finish_user',{actor_id:actor.id,target_id:created.user.id,new_role:b.role});
   if (finishError) return reply(409,{error:'ანგარიში შექმნილია, მაგრამ გამორთულია. ადმინისტრატორმა შეამოწმოს მისი როლი და აღადგინოს მომხმარებლების გვერდიდან.'});
   return reply(201,{id:created.user.id});
  }
  if (b.action === 'password') {
   if (typeof b.id !== 'string' || !/^[0-9a-f-]{36}$/i.test(b.id)) return reply(400,{error:'არასწორი მომხმარებელი.'});
   const {data:target} = await db.from('profiles').select('id').eq('id',b.id).single();
   if (!target) return reply(404,{error:'მომხმარებელი ვერ მოიძებნა.'});
   const {error} = await db.auth.admin.updateUserById(b.id,{password:b.password});
   if (error) return reply(400,{error:'პაროლის შეცვლა ვერ მოხერხდა.'});
   await db.from('audit').insert({user_id:actor.id,action:'user.password',target:b.id});
   return reply(200,{ok:true});
  }
  return reply(400,{error:'უცნობი მოქმედება.'});
 } catch {
  return reply(500,{error:'მოქმედება ვერ შესრულდა. სცადეთ ხელახლა.'});
 }
});
