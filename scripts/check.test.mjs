import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync,existsSync} from 'node:fs';
import {fileURLToPath} from 'node:url';
import {workbook} from '../web/export.js';
const read=p=>readFileSync(new URL('../'+p,import.meta.url),'utf8');
test('GitHub Pages assets use repository-relative paths',()=>{
 const html=read('web/index.html');for(const [,ref] of html.matchAll(/(?:src|href)="([^"]+)"/g)){assert.ok(ref.startsWith('./'));assert.ok(existsSync(new URL('../web/'+ref.slice(2),import.meta.url)))}
 assert.ok(existsSync(new URL('../web/.nojekyll',import.meta.url)));
 const app=read('web/app.js');assert.ok(app.includes("import {api,initBackend}"));assert.ok(!app.includes("fetch('/api/"));assert.ok(!app.includes('Number(b.dataset.password)'));assert.ok(app.includes('configuration()'));
});
test('browser workbook is a valid stored ZIP with safe text cells',()=>{
 const bytes=workbook([['კითხვა','შეფასება'],['=HYPERLINK("https://example.com")',4],['<script>&',2]]),view=new DataView(bytes.buffer);let offset=0;const entries={};
 function crc(b){let c=0xffffffff;for(const x of b){c^=x;for(let i=0;i<8;i++)c=(c>>>1)^((c&1)?0xedb88320:0)}return(c^0xffffffff)>>>0}
 while(view.getUint32(offset,true)===0x04034b50){const size=view.getUint32(offset+18,true),n=view.getUint16(offset+26,true),extra=view.getUint16(offset+28,true);const name=new TextDecoder().decode(bytes.slice(offset+30,offset+30+n));const data=bytes.slice(offset+30+n+extra,offset+30+n+extra+size);assert.equal(crc(data),view.getUint32(offset+14,true));entries[name]=new TextDecoder().decode(data);offset+=30+n+extra+size}
 assert.equal(Object.keys(entries).length,5);assert.equal(view.getUint32(offset,true),0x02014b50);const sheet=entries['xl/worksheets/sheet1.xml'];assert.match(sheet,/inlineStr/);assert.match(sheet,/&lt;script&gt;&amp;/);assert.ok(!sheet.includes('<f>'));assert.match(sheet,/HYPERLINK/);assert.match(sheet,/<v>4<\/v>/);
});
test('migration privilege contract and server-only administration',()=>{
 const sql=read('supabase/migrations/202610220001_initial.sql');for(const table of ['profiles','branches','questions','inspections','answers','audit'])assert.ok(sql.includes(`alter table public.${table} enable row level security`));
 assert.match(sql,/revoke all on public\.profiles.*from anon,authenticated/);
 assert.match(sql,/revoke all on function public\.app_api.*from public,anon/);
 const edge=read('supabase/functions/manage-users/index.ts');assert.ok(edge.indexOf('auth.getUser(token)')<edge.indexOf('auth.admin.createUser'));assert.ok(edge.includes("actor.role !== 'admin'"));
 const config=read('web/config.js');assert.ok(!config.includes('sb_secret_'));assert.ok(config.includes('sb_publishable_'));
});
